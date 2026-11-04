import Foundation
import NetworkExtension

/// Controls only profiles whose provider AND owning application identifiers match.
/// Start returns after the system accepts the request; observe status for connection progress.
@MainActor
public final class WGCNEClient {
    private let owner: String
    private let repository: TunnelManagerRepository
    private let store: ConfigurationStore
    private let operationTimeout: TimeInterval
    private let totalTimeout: TimeInterval
    private var statusManagers: [String: TunnelManagerHandle] = [:]
    private var statusGeneration: UInt64 = 0

    public convenience init(ownerBundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            operationTimeout: TimeInterval = 10) {
        self.init(owner: ownerBundleIdentifier ?? "", repository: SystemTunnelManagerRepository(),
                  store: KeychainConfigurationStore(), operationTimeout: operationTimeout,
                  totalTimeout: 45)
    }

    internal init(owner: String, repository: TunnelManagerRepository, store: ConfigurationStore,
                  operationTimeout: TimeInterval = 10, totalTimeout: TimeInterval = 45) {
        self.owner = owner
        self.repository = repository
        self.store = store
        self.operationTimeout = operationTimeout.isFinite ? min(30, max(0.01, operationTimeout)) : 10
        self.totalTimeout = totalTimeout.isFinite ? min(120, max(0.01, totalTimeout)) : 45
    }

    public func start(providerBundleIdentifier: String, keychainAccessGroup: String,
                      configurationJSON: String, localizedDescription: String? = nil) async throws -> WGCStatus {
        try validateProvider(providerBundleIdentifier)
        guard WGCContract.validIdentifier(keychainAccessGroup),
              localizedDescription.map({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("\0") }) ?? true else {
            throw WGCNEError.invalidArguments
        }
        let data = try WGCContract.configurationData(configurationJSON)
        return try await mutate(providerBundleIdentifier) { fence in
            let existing = try await self.find(providerBundleIdentifier)
            let manager = existing ?? self.repository.makeManager()
            let oldReference = try existing.map { manager -> ProfileReference in
                guard let configuration = manager.configuration as? NETunnelProviderProtocol else {
                    throw WGCNEError.invalidProfile
                }
                return try ProfileReference(configuration: configuration)
            }
            if existing != nil { try await self.disconnect(manager) }
            try Task.checkCancellation()
            let store = self.store
            let reference = try await utilityOperation(timeout: self.operationTimeout, onLateSuccess: { reference in
                try? store.delete(reference: reference, accessGroup: keychainAccessGroup)
            }) {
                try store.put(data, accessGroup: keychainAccessGroup)
            }
            let newReference = ProfileReference(reference: reference, accessGroup: keychainAccessGroup, owner: self.owner)
            var saveSubmitted = false
            do {
                try Task.checkCancellation()
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = providerBundleIdentifier
                configuration.serverAddress = "WGC NE"
                configuration.disconnectOnSleep = false
                configuration.providerConfiguration = newReference.dictionary
                manager.configuration = configuration
                manager.localizedDescription = localizedDescription ?? "WGC NE"
                manager.isEnabled = true
                try await self.preferenceOperation(fence, onSettlement: { succeeded in
                    // Only the raw save result determines which secret is unreferenced.
                    // This reconciliation also runs when its caller has already left.
                    if succeeded {
                        if let oldReference, oldReference.reference != reference {
                            try? await Self.discard(oldReference, from: store)
                        }
                    } else {
                        try? await Self.discard(newReference, from: store)
                    }
                }) { completion in
                    saveSubmitted = true
                    manager.save(completion)
                }
            } catch {
                if !saveSubmitted {
                    // Unlike a submitted save, this reference can never reach preferences.
                    // Schedule directly so caller cancellation cannot cancel its disposal.
                    DispatchQueue.global(qos: .utility).async {
                        try? store.delete(reference: reference, accessGroup: keychainAccessGroup)
                    }
                }
                throw error
            }
            try Task.checkCancellation()
            try await self.preferenceOperation(fence) { manager.reload($0) }
            try Task.checkCancellation()
            do { try manager.start() }
            catch { throw WGCNEError.tunnelStartFailed }
            let state = self.connectionState(manager.status)
            return WGCStatus(state: state == .disconnected || state == .invalid ? .connecting : state)
        }
    }

    public func stop(providerBundleIdentifier: String) async throws -> WGCStatus {
        try validateProvider(providerBundleIdentifier)
        return try await mutate(providerBundleIdentifier) { _ in
            guard let manager = try await self.find(providerBundleIdentifier) else {
                return WGCStatus(state: .disconnected)
            }
            try await self.disconnect(manager)
            return WGCStatus(state: self.connectionState(manager.status))
        }
    }

    /// Call only for an explicit user request to remove the installed profile.
    public func removeProfile(providerBundleIdentifier: String) async throws -> WGCStatus {
        try validateProvider(providerBundleIdentifier)
        return try await mutate(providerBundleIdentifier) { fence in
            guard let manager = try await self.find(providerBundleIdentifier) else {
                return WGCStatus(state: .disconnected)
            }
            let reference = (manager.configuration as? NETunnelProviderProtocol).flatMap {
                try? ProfileReference(configuration: $0)
            }
            try await self.disconnect(manager)
            try Task.checkCancellation()
            let store = self.store
            try await self.preferenceOperation(fence, onSettlement: { succeeded in
                if succeeded, let reference { try await Self.discard(reference, from: store) }
            }) { manager.remove($0) }
            return WGCStatus(state: .disconnected)
        }
    }

    public func status(providerBundleIdentifier: String) async throws -> WGCStatus {
        try validateProvider(providerBundleIdentifier)
        guard let manager = try await statusManager(providerBundleIdentifier) else {
            return WGCStatus(state: .disconnected)
        }
        let state = connectionState(manager.status)
        guard state == .connected || state == .reasserting else { return WGCStatus(state: state) }
        let message = Data("{\"method\":\"status\"}".utf8)
        // Provider statistics are optional: an unresponsive extension must not hide
        // the system's authoritative VPN state or leave a Flutter call pending.
        let core: WGCCoreStatus? = try? await boundedCallback(timeout: min(2, operationTimeout)) { completion in
            do {
                try manager.send(message) { data in
                    guard let data else { completion(.failure(WGCNEError.providerUnavailable)); return }
                    completion(Result { try WGCABIEnvelope<WGCCoreStatus>.decode(data) })
                }
            } catch { completion(.failure(WGCNEError.providerUnavailable)) }
        }
        try Task.checkCancellation()
        return WGCStatus(state: connectionState(manager.status), core: core)
    }

    private func validateProvider(_ identifier: String) throws {
        guard WGCContract.validIdentifier(owner), WGCContract.validIdentifier(identifier) else {
            throw WGCNEError.invalidArguments
        }
    }

    private func statusManager(_ provider: String) async throws -> TunnelManagerHandle? {
        try Task.checkCancellation()
        let generation = ClientConfigurationGeneration.shared.value
        if statusGeneration != generation {
            statusManagers.removeAll()
            statusGeneration = generation
        }
        if let manager = statusManagers[provider] {
            if let configuration = manager.configuration as? NETunnelProviderProtocol,
               configuration.providerBundleIdentifier == provider,
               configuration.providerConfiguration?[WGCContract.ownerKey] as? String == owner {
                return manager
            }
            statusManagers.removeValue(forKey: provider)
        }
        let manager = try await find(provider)
        // An in-flight load must not repopulate a cache invalidated by a mutation
        // or an NEVPNConfigurationChange notification, including object:nil.
        if let manager, generation == ClientConfigurationGeneration.shared.value {
            statusManagers[provider] = manager
        }
        return manager
    }

    private func find(_ provider: String) async throws -> TunnelManagerHandle? {
        let managers: [TunnelManagerHandle] = try await boundedCallback(timeout: operationTimeout) { completion in
            repository.loadAll { managers, error in
                guard error == nil, let managers else {
                    completion(.failure(WGCNEError.preferencesFailure)); return
                }
                completion(.success(managers))
            }
        }
        try Task.checkCancellation()
        let matches = managers.filter { ($0.configuration as? NETunnelProviderProtocol)?.providerBundleIdentifier == provider }
        guard matches.count <= 1 else { throw WGCNEError.profileConflict }
        guard let manager = matches.first else { return nil }
        guard let configuration = manager.configuration as? NETunnelProviderProtocol,
              configuration.providerConfiguration?[WGCContract.ownerKey] as? String == owner else {
            throw WGCNEError.profileConflict
        }
        return manager
    }

    private func preferenceOperation(
        _ fence: ClientPreferenceFence,
        onSettlement: @escaping @MainActor (Bool) async throws -> Void = { _ in },
        _ operation: @MainActor (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let _: Void = try await boundedCallback(timeout: operationTimeout) { completion in
            fence.begin()
            let settlement = ClientPreferenceSettlement(fence: fence, completion: completion, onSettlement: onSettlement)
            operation { error in
                Task { @MainActor in await settlement.finish(succeeded: error == nil) }
            }
        }
    }

    private static func discard(_ reference: ProfileReference, from store: ConfigurationStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try store.delete(reference: reference.reference, accessGroup: reference.accessGroup)
                })
            }
        }
    }

    private func disconnect(_ manager: TunnelManagerHandle) async throws {
        if manager.status == .disconnected || manager.status == .invalid { return }
        manager.stop()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(operationTimeout * 1_000_000_000)
        while manager.status != .disconnected && manager.status != .invalid {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw WGCNEError.timeout }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func mutate<Value>(
        _ provider: String,
        _ operation: @escaping @MainActor (ClientPreferenceFence) async throws -> Value
    ) async throws -> Value {
        if Task.isCancelled { throw WGCNEError.cancelled }
        let task = ClientMutationCoordinator.submit(owner: owner, provider: provider, waitingTimeout: totalTimeout, operation: operation)
        do {
            return try await withTaskCancellationHandler {
                try await boundedCallback(timeout: totalTimeout) { completion in
                    Task { completion(await task.result) }
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            task.cancel()
            throw WGCNEError.redacted(error)
        }
    }

    private func connectionState(_ status: NEVPNStatus) -> WGCConnectionState {
        switch status {
        case .invalid: return .invalid
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .invalid
        }
    }
}

/// Generations are process-wide so a local mutation also invalidates other clients.
/// Notification callbacks may arrive on any queue; no actor-owned state is touched there.
private final class ClientConfigurationGeneration: @unchecked Sendable {
    static let shared = ClientConfigurationGeneration()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: nil) {
            @Sendable [weak self] _ in self?.invalidate()
        }
    }

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The caller's task may finish before an uncancellable preferences operation.
/// Its reservation remains held until every submitted callback and reconciliation settles.
@MainActor
private final class ClientPreferenceFence {
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { pending += 1 }

    func end() {
        pending -= 1
        if pending == 0 {
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitForSettlement() async {
        guard pending != 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class ClientPreferenceSettlement {
    private let fence: ClientPreferenceFence
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private let onSettlement: @MainActor (Bool) async throws -> Void
    private var settled = false

    init(fence: ClientPreferenceFence, completion: @escaping @Sendable (Result<Void, Error>) -> Void,
         onSettlement: @escaping @MainActor (Bool) async throws -> Void) {
        self.fence = fence
        self.completion = completion
        self.onSettlement = onSettlement
    }

    func finish(succeeded: Bool) async {
        guard !settled else { return }
        settled = true
        let result: Result<Void, Error>
        do {
            try await onSettlement(succeeded)
            result = succeeded ? .success(()) : .failure(WGCNEError.preferencesFailure)
        } catch {
            result = .failure(WGCNEError.redacted(error))
        }
        ClientConfigurationGeneration.shared.invalidate()
        fence.end()
        completion(result)
    }
}

@MainActor
private enum ClientMutationCoordinator {
    private struct Key: Hashable {
        let owner: String
        let provider: String
    }
    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }
    private static var tails: [Key: Tail] = [:]

    static func submit<Value>(owner: String, provider: String, waitingTimeout: TimeInterval,
                              operation: @escaping @MainActor (ClientPreferenceFence) async throws -> Value) -> Task<Value, Error> {
        let key = Key(owner: owner, provider: provider)
        let previous = tails[key]?.task
        let fence = ClientPreferenceFence()
        let id = UUID()
        ClientConfigurationGeneration.shared.invalidate()
        let task = Task { @MainActor in
            if let previous {
                let _: Void = try await boundedCallback(timeout: waitingTimeout) { completion in
                    Task { @MainActor [previous, completion] in
                        await previous.value
                        completion(.success(()))
                    }
                }
            }
            try Task.checkCancellation()
            defer { ClientConfigurationGeneration.shared.invalidate() }
            return try await operation(fence)
        }
        let tail = Task { @MainActor in
            // A cancelled queued body can release its captures immediately, but
            // its ordering barrier must still include the previous raw operation.
            await previous?.value
            _ = await task.result
            await fence.waitForSettlement()
            if tails[key]?.id == id { tails.removeValue(forKey: key) }
        }
        tails[key] = Tail(id: id, task: tail)
        return task
    }
}
