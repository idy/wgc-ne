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
    private var mutationTail: Task<Void, Never>?

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
        return try await mutate {
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
            let reference = try await utilityOperation(timeout: self.operationTimeout) {
                try store.put(data, accessGroup: keychainAccessGroup)
            }
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = providerBundleIdentifier
            configuration.serverAddress = "WGC NE"
            configuration.disconnectOnSleep = false
            configuration.providerConfiguration = ProfileReference(
                reference: reference, accessGroup: keychainAccessGroup, owner: self.owner
            ).dictionary
            manager.configuration = configuration
            manager.localizedDescription = localizedDescription ?? "WGC NE"
            manager.isEnabled = true
            do {
                try await self.preferenceOperation { manager.save($0) }
            } catch {
                // A cancelled/timed-out system save may still finish. Keep its referenced
                // item valid; never delete a secret that a late save can still reference.
                if error as? WGCNEError == .preferencesFailure {
                    _ = try? await utilityOperation(timeout: self.operationTimeout) {
                        try store.delete(reference: reference, accessGroup: keychainAccessGroup)
                    }
                }
                throw error
            }
            try Task.checkCancellation()
            try await self.preferenceOperation { manager.reload($0) }
            try Task.checkCancellation()
            if let oldReference, oldReference.reference != reference {
                _ = try? await utilityOperation(timeout: self.operationTimeout) {
                    try store.delete(reference: oldReference.reference, accessGroup: oldReference.accessGroup)
                }
            }
            try Task.checkCancellation()
            do { try manager.start() }
            catch { throw WGCNEError.tunnelStartFailed }
            let state = self.connectionState(manager.status)
            return WGCStatus(state: state == .disconnected || state == .invalid ? .connecting : state)
        }
    }

    public func stop(providerBundleIdentifier: String) async throws -> WGCStatus {
        try validateProvider(providerBundleIdentifier)
        return try await mutate {
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
        return try await mutate {
            guard let manager = try await self.find(providerBundleIdentifier) else {
                return WGCStatus(state: .disconnected)
            }
            let reference = (manager.configuration as? NETunnelProviderProtocol).flatMap {
                try? ProfileReference(configuration: $0)
            }
            try await self.disconnect(manager)
            try Task.checkCancellation()
            try await self.preferenceOperation { manager.remove($0) }
            if let reference {
                let store = self.store
                try await utilityOperation(timeout: self.operationTimeout) {
                    try store.delete(reference: reference.reference, accessGroup: reference.accessGroup)
                }
            }
            return WGCStatus(state: .disconnected)
        }
    }

    public func status(providerBundleIdentifier: String) async throws -> WGCStatus {
        try validateProvider(providerBundleIdentifier)
        guard let manager = try await find(providerBundleIdentifier) else {
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

    private func preferenceOperation(_ operation: (@escaping (Error?) -> Void) -> Void) async throws {
        let _: Void = try await boundedCallback(timeout: operationTimeout) { completion in
            operation { error in
                completion(error == nil ? .success(()) : .failure(WGCNEError.preferencesFailure))
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

    private func mutate<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = mutationTail
        let task = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        mutationTail = Task { _ = await task.result }
        do {
            return try await boundedCallback(timeout: totalTimeout) { completion in
                Task { completion(await task.result) }
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
