import Darwin
import Foundation
import NetworkExtension

/// Subclass in the containing app's PacketTunnel extension and override makeCoreEngine().
/// The provider never instantiates Flutter and never puts configuration into messages.
open class WGCPacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycleLock = NSLock()
    private var controller: ProviderLifecycle?

    private var lifecycle: ProviderLifecycle {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if let controller { return controller }
        let operations = ProviderOperations(
            profile: { [weak self] in self?.protocolConfiguration as? NETunnelProviderProtocol },
            makeCoreEngine: { [weak self] in
                guard let self else { throw WGCNEError.coreUnavailable }
                return try self.makeCoreEngine()
            },
            setSettings: { [weak self] settings, completion in
                guard let self else { completion(WGCNEError.providerUnavailable); return }
                self.setTunnelNetworkSettings(settings, completionHandler: completion)
            },
            cancelTunnel: { [weak self] error in self?.cancelTunnelWithError(error) })
        let controller = ProviderLifecycle(store: KeychainConfigurationStore(), operations: operations)
        self.controller = controller
        return controller
    }

    /// Override to return the extension's separately compiled Go adapter (or another core).
    open func makeCoreEngine() throws -> CoreEngine { throw WGCNEError.coreUnavailable }

    public final override func startTunnel(options: [String: NSObject]? = nil,
                                           completionHandler: @escaping (Error?) -> Void) {
        lifecycle.startTunnel(options: options, completionHandler: completionHandler)
    }

    public final override func stopTunnel(with reason: NEProviderStopReason,
                                          completionHandler: @escaping () -> Void) {
        lifecycle.stopTunnel(with: reason, completionHandler: completionHandler)
    }

    public final override func handleAppMessage(_ messageData: Data,
                                                completionHandler: ((Data?) -> Void)? = nil) {
        lifecycle.handleAppMessage(messageData, completionHandler: completionHandler)
    }

    internal static func errorEnvelope(_ error: WGCNEError) -> Data {
        // All values originate in the fixed error vocabulary, never underlying errors.
        (try? JSONSerialization.data(withJSONObject: [
            "ok": false, "error": ["code": error.code, "message": error.message]
        ])) ?? Data("{\"ok\":false}".utf8)
    }
}

// Tests exercise the same lifecycle without constructing an entitled NEProvider.
internal final class ProviderLifecycle {
    private let worker = DispatchQueue(label: "dev.idy.wgc_ne.provider", qos: .userInitiated)
    private let stateLock = NSLock()
    private var current: ProviderRun?
    private let store: ConfigurationStore
    private let operations: ProviderOperations
    private let timing: ProviderTiming

    init(store: ConfigurationStore, operations: ProviderOperations, timing: ProviderTiming = ProviderTiming()) {
        self.store = store
        self.operations = operations
        self.timing = timing
    }

    func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let run = ProviderRun(completion: completionHandler)
        stateLock.lock()
        guard current == nil else {
            stateLock.unlock()
            completionHandler(WGCNEError.tunnelStartFailed)
            return
        }
        current = run
        stateLock.unlock()
        run.startCompletion.armTimeout(timing.start, value: WGCNEError.timeout, onTimeout: { [weak self, weak run] in
            guard let self, let run else { return }
            self.cancel(run, error: .timeout)
        })
        worker.async { [weak self] in self?.begin(run) }
    }

    func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = ProviderCompletion<Void> { _ in completionHandler() }
        stateLock.lock()
        guard let run = current else { stateLock.unlock(); completion.finish(()); return }
        run.cancelled = true
        run.stopCompletions.append(completion)
        stateLock.unlock()
        // Bound the caller even if NE never completes an apply. Ownership remains
        // with this run until the real apply and subsequent clear have settled.
        completion.armTimeout(timing.applySettings + timing.clearSettings, value: ())
        run.finishStart(WGCNEError.cancelled)
        worker.async { [weak self] in self?.cleanup(run) }
    }

    func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        guard !messageData.isEmpty, messageData.count <= WGCContract.maximumJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              object.count == 1, object["method"] as? String == "status" else {
            completionHandler(WGCPacketTunnelProvider.errorEnvelope(.invalidArguments))
            return
        }
        let reply = ProviderCompletion<Data?>(completionHandler)
        reply.armTimeout(timing.reply, value: WGCPacketTunnelProvider.errorEnvelope(.timeout))
        worker.async { [weak self] in
            guard let self else { reply.finish(WGCPacketTunnelProvider.errorEnvelope(.providerUnavailable)); return }
            self.stateLock.lock()
            let run = self.current
            let running = run.map { !$0.cancelled } ?? false
            self.stateLock.unlock()
            guard running, let engine = run?.engine, run?.started == true else {
                reply.finish(WGCPacketTunnelProvider.errorEnvelope(.providerUnavailable)); return
            }
            do {
                let status = try engine.status()
                let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": status.dictionary])
                reply.finish(data)
            } catch { reply.finish(WGCPacketTunnelProvider.errorEnvelope(.coreFailure)) }
        }
    }

    private func begin(_ run: ProviderRun) {
        guard isActive(run) else { cleanup(run); return }
        do {
            guard let configuration = operations.profile() else {
                throw WGCNEError.invalidProfile
            }
            let reference = try ProfileReference(configuration: configuration)
            let data = try store.read(reference: reference.reference, accessGroup: reference.accessGroup)
            guard isActive(run) else { cleanup(run); return }
            let engine = try operations.makeCoreEngine()
            run.engine = engine
            let settings = try engine.validate(configuration: data)
            let networkSettings = try settings.makeTunnelNetworkSettings()
            guard isActive(run) else { cleanup(run); return }
            run.applyingSettings = true
            setSettings(networkSettings, timeout: timing.applySettings, onTimeout: { [weak self] in
                self?.cancel(run, error: .timeout)
            }) { [weak self] error in
                guard let self else { return }
                run.applyingSettings = false
                guard self.isActive(run) else { self.cleanup(run); return }
                if error != nil { self.cancel(run, error: .tunnelStartFailed); return }
                do {
                    let descriptor = try self.operations.duplicateDescriptor(settings)
                    guard self.isActive(run) else { close(descriptor); self.cleanup(run); return }
                    // CoreEngine consumes this duplicate on success AND failure.
                    try engine.start(ownedFileDescriptor: descriptor, configuration: data)
                    run.started = true
                    guard self.isActive(run) else { self.cleanup(run); return }
                    self.watchHealth(run)
                    run.finishStart(nil)
                } catch { self.cancel(run, error: WGCNEError.redacted(error)) }
            }
        } catch { cancel(run, error: WGCNEError.redacted(error)) }
    }

    private func isActive(_ run: ProviderRun) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return current === run && !run.cancelled
    }

    private func isCurrent(_ run: ProviderRun) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return current === run
    }

    private func cancel(_ run: ProviderRun, error: WGCNEError) {
        stateLock.lock()
        guard current === run, !run.cancelled else { stateLock.unlock(); return }
        run.cancelled = true
        stateLock.unlock()
        run.finishStart(error)
        worker.async { [weak self] in self?.cleanup(run) }
    }

    private func watchHealth(_ run: ProviderRun) {
        guard isActive(run), run.started else { return }
        // CoreEngine calls are bounded by contract and stay on the worker queue.
        // Schedule one check at a time, independently of host status subscriptions.
        let work = DispatchWorkItem { [weak self, weak run] in
            guard let self, let run, self.isActive(run), run.started, let engine = run.engine else { return }
            run.healthWork = nil
            do {
                if try engine.status().state == "running" { self.watchHealth(run); return }
            } catch { /* A failed status operation cannot establish a viable core. */ }
            self.stateLock.lock()
            guard self.current === run, !run.cancelled else { self.stateLock.unlock(); return }
            run.cancelled = true
            self.stateLock.unlock()
            run.tunnelFailure = .coreFailure
            self.cleanup(run)
        }
        run.healthWork = work
        worker.asyncAfter(deadline: .now() + timing.healthCheck, execute: work)
    }

    private func cleanup(_ run: ProviderRun) {
        run.healthWork?.cancel()
        run.healthWork = nil
        // Only NE's actual callback ends an apply. A local deadline may complete
        // callers, but must never let a clear overtake an outstanding apply.
        guard isCurrent(run), !run.applyingSettings else { return }
        guard !run.cleaning else {
            if run.clearDeadlineExpired { finishStops(run) }
            return
        }
        run.cleaning = true
        run.engine?.stop()
        run.engine = nil
        run.started = false
        setSettings(nil, timeout: timing.clearSettings, onTimeout: { [weak self] in
            guard let self, self.isCurrent(run) else { return }
            run.clearDeadlineExpired = true
            self.cancelFailedTunnel(run)
            self.finishStops(run)
        }) { [weak self] _ in self?.finishCleanup(run) }
    }

    private func cancelFailedTunnel(_ run: ProviderRun) {
        guard isCurrent(run), let error = run.tunnelFailure, !run.tunnelCancelled else { return }
        run.tunnelCancelled = true
        operations.cancelTunnel(error)
    }

    private func finishCleanup(_ run: ProviderRun) {
        guard isCurrent(run) else { return }
        // Keep current reserved through cancellation so it cannot cancel a new run.
        cancelFailedTunnel(run)
        stateLock.lock()
        if current === run { current = nil }
        let completions = run.stopCompletions
        run.stopCompletions.removeAll()
        stateLock.unlock()
        completions.forEach { $0.finish(()) }
    }

    private func finishStops(_ run: ProviderRun) {
        stateLock.lock()
        let completions = run.stopCompletions
        run.stopCompletions.removeAll()
        stateLock.unlock()
        completions.forEach { $0.finish(()) }
    }

    private func setSettings(_ settings: NEPacketTunnelNetworkSettings?, timeout: TimeInterval,
                             onTimeout: @escaping () -> Void, completion: @escaping (Error?) -> Void) {
        let deadline = ProviderErrorCompletion { error in if error != nil { onTimeout() } }
        // Resolve both paths on worker: a deadline that wins must cancel the run
        // before a late raw callback can consider starting its core.
        deadline.armTimeout(timeout, value: WGCNEError.timeout, queue: worker)
        let actual = ProviderErrorCompletion { [weak self] error in
            self?.worker.async {
                deadline.finish(nil)
                completion(error == nil ? nil : WGCNEError.tunnelStartFailed)
            }
        }
        let callback: (Error?) -> Void = { actual.finish($0) }
        operations.setSettings(settings, callback)
    }
}

// Internal injection avoids overriding NE methods that Apple forbids subclasses to override.
internal struct ProviderOperations {
    var profile: () -> NETunnelProviderProtocol?
    var makeCoreEngine: () throws -> CoreEngine
    var duplicateDescriptor: (WGCNetworkSettings) throws -> Int32 = UtunFileDescriptor.duplicate
    var setSettings: (NEPacketTunnelNetworkSettings?, @escaping (Error?) -> Void) -> Void
    var cancelTunnel: (Error) -> Void
}

internal struct ProviderTiming {
    var applySettings: TimeInterval = 10
    var clearSettings: TimeInterval = 5
    var reply: TimeInterval = 3
    var start: TimeInterval = 35
    var healthCheck: TimeInterval = 1
}

private final class ProviderRun {
    let startCompletion: ProviderErrorCompletion
    // cancelled and stopCompletions are protected by the provider's state lock.
    var cancelled = false
    var stopCompletions: [ProviderCompletion<Void>] = []
    // Other properties are confined to the provider worker queue.
    var engine: CoreEngine?
    var started = false
    var applyingSettings = false
    var cleaning = false
    var clearDeadlineExpired = false
    var tunnelFailure: WGCNEError?
    var tunnelCancelled = false
    var healthWork: DispatchWorkItem?

    init(completion: @escaping (Error?) -> Void) { startCompletion = ProviderErrorCompletion(completion) }
    func finishStart(_ error: Error?) { startCompletion.finish(error) }
}

/// Exactly-once completion is shared by startup, cancellation, settings, and replies.
internal final class ProviderCompletion<Value> {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }

    func armTimeout(_ timeout: TimeInterval, value: Value,
                    queue: DispatchQueue = .global(qos: .utility), onTimeout: (() -> Void)? = nil) {
        let work = DispatchWorkItem { [weak self] in self?.resolve(value, onFinish: onTimeout) }
        lock.lock()
        guard completion != nil, timeoutWork == nil else { lock.unlock(); return }
        timeoutWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func finish(_ value: Value) { resolve(value, onFinish: nil) }

    private func resolve(_ value: Value, onFinish: (() -> Void)?) {
        lock.lock()
        guard let completion else { lock.unlock(); return }
        self.completion = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        onFinish?()
        completion(value)
    }
}

internal typealias ProviderErrorCompletion = ProviderCompletion<Error?>
