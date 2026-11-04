import Foundation
import NetworkExtension

/// Subclass in the containing app's PacketTunnel extension and override makeCoreEngine().
/// The provider never instantiates Flutter and never puts configuration into messages.
open class WGCPacketTunnelProvider: NEPacketTunnelProvider {
    private let worker = DispatchQueue(label: "dev.idy.wgc_ne.provider", qos: .userInitiated)
    private let stateLock = NSLock()
    private var current: ProviderRun?
    private let store: ConfigurationStore = KeychainConfigurationStore()

    /// Override to return the extension's separately compiled Go adapter (or another core).
    open func makeCoreEngine() throws -> CoreEngine { throw WGCNEError.coreUnavailable }

    public final override func startTunnel(options: [String: NSObject]? = nil,
                                           completionHandler: @escaping (Error?) -> Void) {
        let run = ProviderRun(completion: completionHandler)
        stateLock.lock()
        guard current == nil else {
            stateLock.unlock()
            completionHandler(WGCNEError.tunnelStartFailed)
            return
        }
        current = run
        stateLock.unlock()
        run.armTimeout { [weak self, weak run] in
            guard let self, let run else { return }
            self.cancel(run, error: .timeout)
        }
        worker.async { [weak self] in self?.begin(run) }
    }

    public final override func stopTunnel(with reason: NEProviderStopReason,
                                          completionHandler: @escaping () -> Void) {
        stateLock.lock()
        guard let run = current else { stateLock.unlock(); completionHandler(); return }
        run.cancelled = true
        run.stopCompletions.append(completionHandler)
        stateLock.unlock()
        run.finishStart(WGCNEError.cancelled)
        worker.async { [weak self] in self?.cleanup(run) }
    }

    public final override func handleAppMessage(_ messageData: Data,
                                                completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        guard !messageData.isEmpty, messageData.count <= WGCContract.maximumJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              object.count == 1, object["method"] as? String == "status" else {
            completionHandler(Self.errorEnvelope(.invalidArguments))
            return
        }
        let reply = ProviderReply(completion: completionHandler)
        reply.armTimeout()
        worker.async { [weak self] in
            guard let self else { reply.finish(Self.errorEnvelope(.providerUnavailable)); return }
            self.stateLock.lock()
            let run = self.current
            let running = run.map { !$0.cancelled } ?? false
            self.stateLock.unlock()
            guard running, let engine = run?.engine, run?.started == true else {
                reply.finish(Self.errorEnvelope(.providerUnavailable)); return
            }
            do {
                let status = try engine.status()
                let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": status.dictionary])
                reply.finish(data)
            } catch { reply.finish(Self.errorEnvelope(.coreFailure)) }
        }
    }

    private func begin(_ run: ProviderRun) {
        guard isActive(run) else { cleanup(run); return }
        do {
            guard let configuration = protocolConfiguration as? NETunnelProviderProtocol else {
                throw WGCNEError.invalidProfile
            }
            let reference = try ProfileReference(configuration: configuration)
            let data = try store.read(reference: reference.reference, accessGroup: reference.accessGroup)
            guard isActive(run) else { cleanup(run); return }
            let engine = try makeCoreEngine()
            run.engine = engine
            let settings = try engine.validate(configuration: data)
            let networkSettings = try settings.makeTunnelNetworkSettings()
            guard isActive(run) else { cleanup(run); return }
            run.applyingSettings = true
            setSettings(networkSettings, timeout: 10) { [weak self] error in
                guard let self else { return }
                self.worker.async {
                    run.applyingSettings = false
                    run.settingsApplied = error == nil
                    guard self.isActive(run) else { self.cleanup(run); return }
                    if error != nil { self.fail(run, error: .tunnelStartFailed); return }
                    do {
                        let descriptor = try UtunFileDescriptor.duplicate(for: settings)
                        // CoreEngine consumes this duplicate on success AND failure.
                        try engine.start(ownedFileDescriptor: descriptor, configuration: data)
                        run.started = true
                        guard self.isActive(run) else { self.cleanup(run); return }
                        run.finishStart(nil)
                    } catch { self.fail(run, error: WGCNEError.redacted(error)) }
                }
            }
        } catch { fail(run, error: WGCNEError.redacted(error)) }
    }

    private func isActive(_ run: ProviderRun) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return current === run && !run.cancelled
    }

    private func cancel(_ run: ProviderRun, error: WGCNEError) {
        stateLock.lock()
        guard current === run else { stateLock.unlock(); return }
        run.cancelled = true
        stateLock.unlock()
        run.finishStart(error)
        worker.async { [weak self] in self?.cleanup(run) }
    }

    private func fail(_ run: ProviderRun, error: WGCNEError) {
        stateLock.lock()
        run.cancelled = true
        stateLock.unlock()
        run.finishStart(error)
        cleanup(run)
    }

    private func cleanup(_ run: ProviderRun) {
        // An in-flight network-settings operation has a bounded callback and will
        // re-enter cleanup. Never discard settings before stopping the core.
        guard !run.applyingSettings, !run.cleaning else { return }
        run.cleaning = true
        run.engine?.stop()
        run.engine = nil
        run.started = false
        setSettings(nil, timeout: 5) { [weak self] _ in
            guard let self else { return }
            self.worker.async {
                self.stateLock.lock()
                if self.current === run { self.current = nil }
                let completions = run.stopCompletions
                run.stopCompletions.removeAll()
                self.stateLock.unlock()
                completions.forEach { $0() }
            }
        }
    }

    private func setSettings(_ settings: NEPacketTunnelNetworkSettings?, timeout: TimeInterval,
                             completion: @escaping (Error?) -> Void) {
        let once = ProviderErrorCompletion(completion)
        once.armTimeout(timeout)
        setTunnelNetworkSettings(settings) { error in once.finish(error == nil ? nil : WGCNEError.tunnelStartFailed) }
    }

    internal static func errorEnvelope(_ error: WGCNEError) -> Data {
        // All values originate in the fixed error vocabulary, never underlying errors.
        (try? JSONSerialization.data(withJSONObject: [
            "ok": false, "error": ["code": error.code, "message": error.message]
        ])) ?? Data("{\"ok\":false}".utf8)
    }
}

private final class ProviderRun {
    let startCompletion: ProviderErrorCompletion
    // cancelled and stopCompletions are protected by the provider's state lock.
    var cancelled = false
    var stopCompletions: [() -> Void] = []
    // Other properties are confined to the provider worker queue.
    var engine: CoreEngine?
    var started = false
    var applyingSettings = false
    var settingsApplied = false
    var cleaning = false
    private var timeoutWork: DispatchWorkItem?
    private let timeoutLock = NSLock()

    init(completion: @escaping (Error?) -> Void) { startCompletion = ProviderErrorCompletion(completion) }

    func armTimeout(_ cancel: @escaping () -> Void) {
        let work = DispatchWorkItem(block: cancel)
        timeoutLock.lock()
        timeoutWork = work
        timeoutLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 35, execute: work)
    }

    func finishStart(_ error: Error?) {
        timeoutLock.lock()
        timeoutWork?.cancel()
        timeoutWork = nil
        timeoutLock.unlock()
        startCompletion.finish(error)
    }
}

/// Exactly-once completion is shared by startup, cancellation, and deadline paths.
internal final class ProviderErrorCompletion {
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    init(_ completion: @escaping (Error?) -> Void) { self.completion = completion }

    func armTimeout(_ timeout: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.finish(WGCNEError.timeout) }
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        timeoutWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func finish(_ error: Error?) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        completion?(error)
    }
}

private final class ProviderReply {
    private let lock = NSLock()
    private var completion: ((Data?) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    init(completion: @escaping (Data?) -> Void) { self.completion = completion }
    func armTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(WGCPacketTunnelProvider.errorEnvelope(.timeout))
        }
        lock.lock()
        timeoutWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: work)
    }
    func finish(_ data: Data) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        completion?(data)
    }
}
