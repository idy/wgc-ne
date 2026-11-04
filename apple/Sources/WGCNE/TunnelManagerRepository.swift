import Foundation
import NetworkExtension

@MainActor
internal protocol TunnelManagerHandle: AnyObject {
    var configuration: NEVPNProtocol? { get set }
    var localizedDescription: String? { get set }
    var isEnabled: Bool { get set }
    var status: NEVPNStatus { get }
    func save(_ completion: @escaping (Error?) -> Void)
    func reload(_ completion: @escaping (Error?) -> Void)
    func remove(_ completion: @escaping (Error?) -> Void)
    func start() throws
    func stop()
    func send(_ message: Data, completion: @escaping (Data?) -> Void) throws
}

@MainActor
internal protocol TunnelManagerRepository {
    func loadAll(_ completion: @escaping ([TunnelManagerHandle]?, Error?) -> Void)
    func makeManager() -> TunnelManagerHandle
}

@MainActor
internal struct SystemTunnelManagerRepository: TunnelManagerRepository {
    func loadAll(_ completion: @escaping ([TunnelManagerHandle]?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            Task { @MainActor in
                completion(managers?.map { SystemTunnelManager($0) }, error)
            }
        }
    }

    func makeManager() -> TunnelManagerHandle { SystemTunnelManager(NETunnelProviderManager()) }
}

@MainActor
private final class SystemTunnelManager: TunnelManagerHandle {
    let manager: NETunnelProviderManager
    init(_ manager: NETunnelProviderManager) { self.manager = manager }

    var configuration: NEVPNProtocol? {
        get { manager.protocolConfiguration }
        set { manager.protocolConfiguration = newValue }
    }
    var localizedDescription: String? {
        get { manager.localizedDescription }
        set { manager.localizedDescription = newValue }
    }
    var isEnabled: Bool {
        get { manager.isEnabled }
        set { manager.isEnabled = newValue }
    }
    var status: NEVPNStatus { manager.connection.status }
    func save(_ completion: @escaping (Error?) -> Void) { manager.saveToPreferences { completion($0) } }
    func reload(_ completion: @escaping (Error?) -> Void) { manager.loadFromPreferences { completion($0) } }
    func remove(_ completion: @escaping (Error?) -> Void) { manager.removeFromPreferences { completion($0) } }
    func start() throws { try manager.connection.startVPNTunnel() }
    func stop() { manager.connection.stopVPNTunnel() }
    func send(_ message: Data, completion: @escaping (Data?) -> Void) throws {
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw WGCNEError.providerUnavailable
        }
        try session.sendProviderMessage(message, responseHandler: completion)
    }
}

internal struct ProfileReference {
    let reference: Data
    let accessGroup: String
    let owner: String

    init(configuration: NETunnelProviderProtocol) throws {
        guard let metadata = configuration.providerConfiguration,
              let reference = metadata[WGCContract.referenceKey] as? Data,
              !reference.isEmpty, reference.count <= 4096,
              let accessGroup = metadata[WGCContract.accessGroupKey] as? String,
              let owner = metadata[WGCContract.ownerKey] as? String,
              WGCContract.validIdentifier(accessGroup), WGCContract.validIdentifier(owner) else {
            throw WGCNEError.invalidProfile
        }
        self.reference = reference
        self.accessGroup = accessGroup
        self.owner = owner
    }

    init(reference: Data, accessGroup: String, owner: String) {
        self.reference = reference
        self.accessGroup = accessGroup
        self.owner = owner
    }

    var dictionary: [String: Any] {
        [WGCContract.referenceKey: reference, WGCContract.accessGroupKey: accessGroup, WGCContract.ownerKey: owner]
    }
}
