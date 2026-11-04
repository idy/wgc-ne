import Foundation
import NetworkExtension
import XCTest
@testable import WGCNE

@MainActor
final class ClientTests: XCTestCase {
    private let owner = "dev.example.consumer"
    private let provider = "dev.example.consumer.tunnel"
    private let group = "TEAM.dev.example.shared"

    private var configuration: String {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        return "{\"version\":1,\"private_key\":\"\(key)\",\"addresses\":[\"10.7.0.2/32\"],\"peers\":[{}]}"
    }

    func testStartSavesOnlyReferenceAndOwnershipMetadata() async throws {
        let repository = FakeRepository()
        let store = FakeStore()
        let client = WGCNEClient(owner: owner, repository: repository, store: store)
        let status = try await client.start(providerBundleIdentifier: provider, keychainAccessGroup: group,
                                            configurationJSON: configuration)
        XCTAssertEqual(status.state, .connecting)
        let manager = try XCTUnwrap(repository.managers.first)
        let protocolConfiguration = try XCTUnwrap(manager.configuration as? NETunnelProviderProtocol)
        let metadata = try XCTUnwrap(protocolConfiguration.providerConfiguration)
        XCTAssertEqual(Set(metadata.keys), Set([WGCContract.referenceKey, WGCContract.accessGroupKey, WGCContract.ownerKey]))
        XCTAssertEqual(metadata[WGCContract.ownerKey] as? String, owner)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(manager.events, ["save", "reload", "start"])
    }

    func testForeignAndAmbiguousProfilesAreNeverModified() async throws {
        let repository = FakeRepository()
        let foreign = ownedManager(owner: "dev.other.app")
        repository.managers = [foreign]
        let client = WGCNEClient(owner: owner, repository: repository, store: FakeStore())
        do { _ = try await client.removeProfile(providerBundleIdentifier: provider); XCTFail("Must reject foreign owner") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        XCTAssertTrue(foreign.events.isEmpty)
        repository.managers = [ownedManager(owner: owner), ownedManager(owner: owner)]
        do { _ = try await client.stop(providerBundleIdentifier: provider); XCTFail("Must reject ambiguous profiles") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        XCTAssertTrue(repository.managers.allSatisfy { $0.events.isEmpty })
    }

    func testStopAndRemovalStopBeforeDeletingSecret() async throws {
        let repository = FakeRepository()
        let store = FakeStore()
        let reference = try store.put(Data(configuration.utf8), accessGroup: group)
        let manager = ownedManager(owner: owner, reference: reference)
        manager.currentStatus = .connected
        repository.managers = [manager]
        let client = WGCNEClient(owner: owner, repository: repository, store: store)
        let result = try await client.removeProfile(providerBundleIdentifier: provider)
        XCTAssertEqual(result.state, .disconnected)
        XCTAssertEqual(manager.events, ["stop", "remove"])
        XCTAssertEqual(store.count, 0)
    }

    func testUnresponsiveProviderReturnsSystemStatusWithoutCore() async throws {
        let repository = FakeRepository()
        let manager = ownedManager(owner: owner)
        manager.currentStatus = .connected
        manager.reply = nil
        repository.managers = [manager]
        let client = WGCNEClient(owner: owner, repository: repository, store: FakeStore(), operationTimeout: 0.02)
        let result = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(result.state, .connected)
        XCTAssertNil(result.core)
    }

    func testLoadAndSaveHaveDeadlinesAndLateSaveRetainsReference() async throws {
        let repository = FakeRepository()
        repository.dropLoad = true
        let store = FakeStore()
        let client = WGCNEClient(owner: owner, repository: repository, store: store, operationTimeout: 0.02)
        do { _ = try await client.status(providerBundleIdentifier: provider); XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        repository.dropLoad = false
        repository.dropSave = true
        do {
            _ = try await client.start(providerBundleIdentifier: provider, keychainAccessGroup: group, configurationJSON: configuration)
            XCTFail("Must time out")
        } catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertEqual(store.count, 1, "A late system save must still reference a valid Keychain item")
        XCTAssertFalse(repository.managers.first!.events.contains("start"))
    }

    func testConcurrentMutationsAreSerialized() async throws {
        let repository = FakeRepository()
        let client = WGCNEClient(owner: owner, repository: repository, store: FakeStore())
        async let first = client.start(providerBundleIdentifier: provider, keychainAccessGroup: group, configurationJSON: configuration)
        async let second = client.stop(providerBundleIdentifier: provider)
        _ = try await (first, second)
        let events = try XCTUnwrap(repository.managers.first).events
        XCTAssertEqual(events, ["save", "reload", "start", "stop"])
    }

    private func ownedManager(owner: String, reference: Data = Data([1])) -> FakeManager {
        let manager = FakeManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = provider
        configuration.providerConfiguration = ProfileReference(reference: reference, accessGroup: group, owner: owner).dictionary
        manager.configuration = configuration
        return manager
    }
}

@MainActor
private final class FakeRepository: TunnelManagerRepository {
    var managers: [FakeManager] = []
    var dropLoad = false
    var dropSave = false
    func loadAll(_ completion: @escaping ([TunnelManagerHandle]?, Error?) -> Void) {
        if !dropLoad { completion(managers, nil) }
    }
    func makeManager() -> TunnelManagerHandle {
        let manager = FakeManager()
        manager.dropSave = dropSave
        managers.append(manager)
        return manager
    }
}

@MainActor
private final class FakeManager: TunnelManagerHandle {
    var configuration: NEVPNProtocol?
    var localizedDescription: String?
    var isEnabled = false
    var currentStatus: NEVPNStatus = .disconnected
    var status: NEVPNStatus { currentStatus }
    var events: [String] = []
    var dropSave = false
    var reply: Data?
    func save(_ completion: @escaping (Error?) -> Void) { events.append("save"); if !dropSave { completion(nil) } }
    func reload(_ completion: @escaping (Error?) -> Void) { events.append("reload"); completion(nil) }
    func remove(_ completion: @escaping (Error?) -> Void) { events.append("remove"); completion(nil) }
    func start() throws { events.append("start"); currentStatus = .connecting }
    func stop() { events.append("stop"); currentStatus = .disconnected }
    func send(_ message: Data, completion: @escaping (Data?) -> Void) throws { if let reply { completion(reply) } }
}

private final class FakeStore: ConfigurationStore {
    private let lock = NSLock()
    private var values: [Data: Data] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func put(_ configuration: Data, accessGroup: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let reference = Data(UUID().uuidString.utf8)
        values[reference] = configuration
        return reference
    }
    func read(reference: Data, accessGroup: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[reference] else { throw WGCNEError.keychainFailure }
        return value
    }
    func delete(reference: Data, accessGroup: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference)
    }
}
