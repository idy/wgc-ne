import Foundation
import NetworkExtension
import XCTest
@testable import WGCNE

@MainActor
final class ClientTests: XCTestCase {
    private let owner = "dev.example.consumer"
    private let provider = "dev.example.consumer.tunnel.\(UUID().uuidString)"
    private let group = "TEAM.dev.example.shared"

    private var configuration: String {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        return "{\"version\":1,\"private_key\":\"\(key)\",\"addresses\":[\"10.7.0.2/32\"],\"peers\":[{}]}"
    }

    func testStartSavesOnlyReferenceAndOwnershipMetadata() async throws {
        let repository = FakeRepository()
        repository.backgroundCallbacks = true
        let store = FakeStore()
        let client = makeClient(repository, store)
        let status = try await start(client)
        XCTAssertEqual(status.state, .connecting)
        let manager = try XCTUnwrap(repository.savedManagers.first)
        let protocolConfiguration = try XCTUnwrap(manager.configuration as? NETunnelProviderProtocol)
        let metadata = try XCTUnwrap(protocolConfiguration.providerConfiguration)
        XCTAssertEqual(Set(metadata.keys), Set([WGCContract.referenceKey, WGCContract.accessGroupKey, WGCContract.ownerKey]))
        XCTAssertEqual(metadata[WGCContract.ownerKey] as? String, owner)
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.allWorkWasOffMain)
        XCTAssertEqual(manager.events, ["save", "reload", "start"])
    }

    func testForeignAndAmbiguousProfilesAreNeverModified() async throws {
        let repository = FakeRepository()
        let foreign = ownedManager(owner: "dev.other.app")
        repository.savedManagers = [foreign]
        let client = makeClient(repository)
        do { _ = try await client.removeProfile(providerBundleIdentifier: provider); XCTFail("Must reject foreign owner") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        XCTAssertTrue(foreign.events.isEmpty)
        repository.savedManagers = [ownedManager(owner: owner), ownedManager(owner: owner)]
        do { _ = try await client.stop(providerBundleIdentifier: provider); XCTFail("Must reject ambiguous profiles") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        XCTAssertTrue(repository.savedManagers.allSatisfy { $0.events.isEmpty })
    }

    func testStopAndRemovalStopBeforeDeletingSecret() async throws {
        let repository = FakeRepository()
        let store = FakeStore()
        let reference = try store.put(Data(configuration.utf8), accessGroup: group)
        let manager = ownedManager(owner: owner, reference: reference)
        manager.currentStatus = .connected
        repository.savedManagers = [manager]
        let result = try await makeClient(repository, store).removeProfile(providerBundleIdentifier: provider)
        XCTAssertEqual(result.state, .disconnected)
        XCTAssertEqual(manager.events, ["stop", "remove"])
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(repository.savedManagers.isEmpty)
        XCTAssertEqual(store.deleteCount(reference), 1)
    }

    func testUnresponsiveProviderReturnsSystemStatusWithoutCore() async throws {
        let repository = FakeRepository()
        let manager = ownedManager(owner: owner)
        manager.currentStatus = .connected
        repository.savedManagers = [manager]
        let result = try await makeClient(repository, operationTimeout: 0.03).status(providerBundleIdentifier: provider)
        XCTAssertEqual(result.state, .connected)
        XCTAssertNil(result.core)
    }

    func testLoadHasDeadline() async throws {
        let repository = FakeRepository()
        repository.dropLoad = true
        let client = makeClient(repository, operationTimeout: 0.03)
        do { _ = try await client.status(providerBundleIdentifier: provider); XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
    }

    func testHeldSaveKeepsReservationBeyondDeadlineAndRetryRecoversOneProfile() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        repository.backgroundCallbacks = true
        let store = FakeStore()
        let client = makeClient(repository, store, operationTimeout: 0.03, totalTimeout: 0.06)
        do { _ = try await start(client); XCTFail("Held save must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        let manager = try XCTUnwrap(repository.createdManagers.first)
        XCTAssertTrue(repository.savedManagers.isEmpty, "Creating a handle does not publish preferences")
        XCTAssertEqual(store.count, 1, "The submitted save still needs a valid secret")
        XCTAssertEqual(manager.events, ["save"])

        let retryStarted = Date()
        do { _ = try await start(client); XCTFail("Queued retry must remain bounded") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(retryStarted), 0.5)
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertEqual(repository.loadCount, 1, "A retry cannot discover or create profiles across a pending raw save")

        manager.holdSave = false
        manager.finishSave()
        _ = try await start(client)
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertEqual(repository.savedManagers.count, 1)
        XCTAssertEqual(store.count, 1, "A successful replacement disposes the previous secret")
        XCTAssertEqual(manager.events, ["save", "save", "reload", "start"])
        _ = try await client.stop(providerBundleIdentifier: provider)
        _ = try await client.removeProfile(providerBundleIdentifier: provider)
        XCTAssertEqual(Array(manager.events.suffix(2)), ["stop", "remove"])
        XCTAssertTrue(repository.savedManagers.isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    func testTotalDeadlineKeepsRawSaveReservationAcrossClients() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        let store = FakeStore()
        let first = makeClient(repository, store, operationTimeout: 1, totalTimeout: 0.04)
        let second = makeClient(repository, store, operationTimeout: 1, totalTimeout: 0.04)
        do { _ = try await start(first); XCTFail("Total deadline must bound a submitted save") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        do { _ = try await start(second); XCTFail("The next client must remain queued and bounded") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertEqual(repository.loadCount, 1)
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertEqual(store.count, 1)
        let manager = try XCTUnwrap(repository.createdManagers.first)
        XCTAssertEqual(manager.events, ["save"])
        manager.finishSave()
        // Use a longer caller deadline to verify recovery after both timed-out callers.
        let recovered = makeClient(repository, store)
        _ = try await recovered.removeProfile(providerBundleIdentifier: provider)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(repository.savedManagers.isEmpty)
    }

    func testQueuedCancellationReturnsBeforeHeldSaveSettles() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        let client = makeClient(repository, operationTimeout: 0.03, totalTimeout: 2)
        do { _ = try await start(client); XCTFail("Held save must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        let queued = Task { try await self.start(client) }
        await Task.yield()
        queued.cancel()
        let began = Date()
        do { _ = try await queued.value; XCTFail("Queued work must cancel") }
        catch { XCTAssertEqual(error as? WGCNEError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
        XCTAssertEqual(repository.createdManagers.count, 1)
        repository.createdManagers[0].finishSave()
        _ = try await client.removeProfile(providerBundleIdentifier: provider)
    }

    func testCancelledQueuedStartReleasesClientAndPayloadBeforeRawSaveSettles() async throws {
        try await assertAbandonedQueuedStartReleasesCaptures(cancel: true)
    }

    func testTimedOutQueuedStartReleasesClientAndPayloadBeforeRawSaveSettles() async throws {
        try await assertAbandonedQueuedStartReleasesCaptures(cancel: false)
    }

    private func assertAbandonedQueuedStartReleasesCaptures(cancel: Bool) async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        let firstStore = FakeStore()
        let firstClient = makeClient(repository, firstStore, operationTimeout: 0.03)
        do { _ = try await start(firstClient); XCTFail("The original raw save must remain held") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        let manager = try XCTUnwrap(repository.createdManagers.first)
        defer { if manager.pendingSaveCount != 0 { manager.finishSave() } }

        var payload: ClientLifetimePayload? = ClientLifetimePayload(configuration: configuration)
        var queuedStore: FakeStore? = FakeStore(retaining: payload)
        var queuedClient: WGCNEClient? = makeClient(repository, queuedStore!, totalTimeout: cancel ? 2 : 0.04)
        let releasedPayload = ClientWeakReference(payload)
        let releasedStore = ClientWeakReference(queuedStore)
        let releasedClient = ClientWeakReference(queuedClient)
        var queued: Task<WGCStatus, Error>? = Task { [client = queuedClient!] in try await self.start(client) }
        await Task.yield()
        if cancel { queued?.cancel() }
        do { _ = try await queued!.value; XCTFail("The queued caller must leave before the raw save settles") }
        catch { XCTAssertEqual(error as? WGCNEError, cancel ? .cancelled : .timeout) }
        queued = nil
        queuedClient = nil
        queuedStore = nil
        payload = nil
        try await waitUntil { releasedClient.value == nil && releasedStore.value == nil && releasedPayload.value == nil }
        XCTAssertEqual(manager.pendingSaveCount, 1, "Capture disposal must not depend on the first callback")

        let thirdClient = makeClient(repository, firstStore, totalTimeout: 0.04)
        do { _ = try await start(thirdClient); XCTFail("A third mutation cannot overtake the original raw save") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertEqual(repository.loadCount, 1)
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertTrue(repository.savedManagers.isEmpty)
        XCTAssertEqual(firstStore.count, 1)

        manager.finishSave()
        _ = try await firstClient.removeProfile(providerBundleIdentifier: provider)
        XCTAssertTrue(repository.savedManagers.isEmpty)
        XCTAssertEqual(firstStore.count, 0)
    }

    func testLateSaveFailureDisposesOnlyNewReferenceBeforeRetry() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        let store = FakeStore()
        let client = makeClient(repository, store, operationTimeout: 0.03)
        do { _ = try await start(client); XCTFail("Held save must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        let failed = try XCTUnwrap(repository.createdManagers.first)
        let reference = try profileReference(failed).reference
        repository.holdSaves = false
        failed.finishSave(error: WGCNEError.preferencesFailure, duplicate: true)
        _ = try await start(client)
        XCTAssertEqual(repository.createdManagers.count, 2)
        XCTAssertEqual(repository.savedManagers.count, 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.deleteCount(reference), 1)
        _ = try await client.removeProfile(providerBundleIdentifier: provider)
    }

    func testLateReplacementSuccessDeletesOldSecretAndKeepsSubmittedSecret() async throws {
        let repository = FakeRepository()
        let store = FakeStore()
        let oldReference = try store.put(Data(configuration.utf8), accessGroup: group)
        let manager = ownedManager(owner: owner, reference: oldReference)
        manager.holdSave = true
        repository.savedManagers = [manager]
        let client = makeClient(repository, store, operationTimeout: 0.03)
        do { _ = try await start(client); XCTFail("Held replacement must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        let newReference = try profileReference(manager).reference
        XCTAssertEqual(store.count, 2)
        manager.finishSave(duplicate: true)
        _ = try await client.stop(providerBundleIdentifier: provider)
        XCTAssertEqual(store.deleteCount(oldReference), 1)
        XCTAssertEqual(store.deleteCount(newReference), 0)
        XCTAssertNotNil(try? store.read(reference: newReference, accessGroup: group))
        _ = try await client.removeProfile(providerBundleIdentifier: provider)
    }

    func testCancellationAfterSaveSubmissionRetainsSecretUntilRawSuccess() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        let store = FakeStore()
        let client = makeClient(repository, store)
        let task = Task { try await self.start(client) }
        try await waitUntil { repository.createdManagers.first?.pendingSaveCount == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Caller must cancel promptly") }
        catch { XCTAssertEqual(error as? WGCNEError, .cancelled) }
        let manager = try XCTUnwrap(repository.createdManagers.first)
        let reference = try profileReference(manager).reference
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.deleteCount(reference), 0)
        manager.finishSave()
        _ = try await client.stop(providerBundleIdentifier: provider)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.deleteCount(reference), 0)
        _ = try await client.removeProfile(providerBundleIdentifier: provider)
    }

    func testLateRemoveSettlesBeforeNewStartAndDisposesRemovedSecret() async throws {
        let repository = FakeRepository()
        let store = FakeStore()
        let reference = try store.put(Data(configuration.utf8), accessGroup: group)
        let manager = ownedManager(owner: owner, reference: reference)
        manager.holdRemove = true
        repository.savedManagers = [manager]
        let client = makeClient(repository, store, operationTimeout: 0.03, totalTimeout: 0.06)
        do { _ = try await client.removeProfile(providerBundleIdentifier: provider); XCTFail("Held remove must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        do { _ = try await start(client); XCTFail("Start must not cross pending removal") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertTrue(repository.createdManagers.isEmpty)
        XCTAssertEqual(store.count, 1)
        manager.finishRemove()
        _ = try await start(client)
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertEqual(repository.savedManagers.count, 1)
        XCTAssertEqual(store.deleteCount(reference), 1)
        _ = try await client.removeProfile(providerBundleIdentifier: provider)
    }

    func testConcurrentMutationsAreSerialized() async throws {
        let repository = FakeRepository()
        let client = makeClient(repository)
        async let first = start(client)
        async let second = client.stop(providerBundleIdentifier: provider)
        _ = try await (first, second)
        let events = try XCTUnwrap(repository.savedManagers.first).events
        XCTAssertEqual(events, ["save", "reload", "start", "stop"])
    }

    func testSeparateClientsSerializeFreshStartsThroughActualSaveSettlement() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        repository.backgroundCallbacks = true
        let store = FakeStore()
        let firstClient = makeClient(repository, store)
        let secondClient = makeClient(repository, store)
        let first = Task { try await self.start(firstClient) }
        try await waitUntil { repository.createdManagers.first?.pendingSaveCount == 1 }
        let second = Task { try await self.start(secondClient) }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(repository.loadCount, 1)
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertTrue(repository.savedManagers.isEmpty)
        let manager = repository.createdManagers[0]
        manager.holdSave = false
        manager.finishSave()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertEqual(repository.savedManagers.count, 1)
        XCTAssertEqual(manager.events, ["save", "reload", "start", "stop", "save", "reload", "start"])
        XCTAssertEqual(store.count, 1)
        _ = try await secondClient.removeProfile(providerBundleIdentifier: provider)
    }

    func testSeparateClientCannotCrossAnotherClientsTimedOutSave() async throws {
        let repository = FakeRepository()
        repository.holdSaves = true
        let store = FakeStore()
        let first = makeClient(repository, store, operationTimeout: 0.03)
        let second = makeClient(repository, store, operationTimeout: 0.03, totalTimeout: 0.06)
        do { _ = try await start(first); XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        do { _ = try await start(second); XCTFail("Second client must remain bounded") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertEqual(repository.createdManagers.count, 1)
        XCTAssertEqual(repository.loadCount, 1)
        repository.createdManagers[0].finishSave()
        _ = try await second.removeProfile(providerBundleIdentifier: provider)
        XCTAssertEqual(store.count, 0)
    }

    func testSlowPutTimeoutDisposesUndeliveredSecretExactlyOnce() async throws {
        let repository = FakeRepository()
        let store = FakeStore(holdPut: true)
        let client = makeClient(repository, store, operationTimeout: 0.03)
        let task = Task { try await self.start(client) }
        try await waitUntil { store.didBeginPut }
        do { _ = try await task.value; XCTFail("Slow put must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        XCTAssertTrue(repository.createdManagers[0].events.isEmpty)
        store.releasePut()
        try await waitUntil { store.totalDeletes == 1 }
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.totalDeletes, 1)
        XCTAssertTrue(store.allWorkWasOffMain)
        XCTAssertTrue(repository.savedManagers.isEmpty)
    }

    func testSlowPutCancellationDisposesUndeliveredSecretExactlyOnce() async throws {
        let repository = FakeRepository()
        let store = FakeStore(holdPut: true)
        let client = makeClient(repository, store)
        let task = Task { try await self.start(client) }
        try await waitUntil { store.didBeginPut }
        task.cancel()
        do { _ = try await task.value; XCTFail("Slow put must cancel") }
        catch { XCTAssertEqual(error as? WGCNEError, .cancelled) }
        store.releasePut()
        try await waitUntil { store.totalDeletes == 1 }
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.totalDeletes, 1)
        XCTAssertTrue(store.allWorkWasOffMain)
        XCTAssertTrue(repository.createdManagers[0].events.isEmpty)
        XCTAssertTrue(repository.savedManagers.isEmpty)
    }

    func testStatusCachesValidatedManagerButReadsLiveStateAndCounters() async throws {
        let repository = FakeRepository()
        repository.backgroundCallbacks = true
        let manager = ownedManager(owner: owner)
        repository.savedManagers = [manager]
        let client = makeClient(repository)
        _ = try await client.status(providerBundleIdentifier: provider)
        _ = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(repository.loadCount, 1)
        manager.currentStatus = .connected
        manager.reply = Data("{\"ok\":true,\"result\":{\"state\":\"running\",\"bytes_sent\":7}}".utf8)
        let first = try await client.status(providerBundleIdentifier: provider)
        manager.currentStatus = .reasserting
        manager.reply = Data("{\"ok\":true,\"result\":{\"state\":\"running\",\"bytes_sent\":19}}".utf8)
        let second = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(first.state, .connected)
        XCTAssertEqual(first.core?.bytesSent, 7)
        XCTAssertEqual(second.state, .reasserting)
        XCTAssertEqual(second.core?.bytesSent, 19)
        XCTAssertEqual(manager.sendCount, 2)
        XCTAssertEqual(repository.loadCount, 1)
    }

    func testMissingStatusProfileIsNotCached() async throws {
        let repository = FakeRepository()
        let client = makeClient(repository)
        _ = try await client.status(providerBundleIdentifier: provider)
        repository.savedManagers = [ownedManager(owner: owner)]
        _ = try await client.status(providerBundleIdentifier: provider)
        _ = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(repository.loadCount, 2)
    }

    func testNilObjectConfigurationNotificationInvalidatesStatusCacheFromBackground() async throws {
        let repository = FakeRepository()
        repository.savedManagers = [ownedManager(owner: owner)]
        let client = makeClient(repository)
        _ = try await client.status(providerBundleIdentifier: provider)
        let replacement = ownedManager(owner: owner)
        replacement.currentStatus = .invalid
        repository.savedManagers = [replacement]
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
                continuation.resume()
            }
        }
        let result = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(result.state, .invalid)
        XCTAssertEqual(repository.loadCount, 2)
    }

    func testMutationsAlwaysDiscoverFreshProfilesAndInvalidateOtherClientCache() async throws {
        let repository = FakeRepository()
        repository.savedManagers = [ownedManager(owner: owner)]
        let first = makeClient(repository)
        let second = makeClient(repository)
        _ = try await first.status(providerBundleIdentifier: provider)
        _ = try await second.stop(providerBundleIdentifier: provider)
        _ = try await first.status(providerBundleIdentifier: provider)
        XCTAssertEqual(repository.loadCount, 3)
        repository.savedManagers.append(ownedManager(owner: owner))
        do { _ = try await start(first); XCTFail("A cached manager cannot bypass fresh duplicate detection") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        XCTAssertTrue(repository.savedManagers.allSatisfy { $0.events.isEmpty })
    }

    func testInflightLoadCannotRepopulateCacheAfterConfigurationNotification() async throws {
        let repository = FakeRepository()
        repository.savedManagers = [ownedManager(owner: owner)]
        repository.holdLoads = true
        let client = makeClient(repository)
        let status = Task { try await client.status(providerBundleIdentifier: self.provider) }
        try await waitUntil { repository.pendingLoadCount == 1 }
        repository.savedManagers = [ownedManager(owner: "dev.other.app")]
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        repository.holdLoads = false
        repository.finishLoad()
        _ = try await status.value
        do { _ = try await client.status(providerBundleIdentifier: provider); XCTFail("Stale load must not be cached") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        XCTAssertEqual(repository.loadCount, 2)
    }

    func testInflightLoadCannotRepopulateCacheAfterLocalMutation() async throws {
        let repository = FakeRepository()
        let manager = ownedManager(owner: owner)
        repository.savedManagers = [manager]
        repository.holdLoads = true
        let client = makeClient(repository)
        let status = Task { try await client.status(providerBundleIdentifier: self.provider) }
        try await waitUntil { repository.pendingLoadCount == 1 }
        repository.holdLoads = false
        _ = try await client.stop(providerBundleIdentifier: provider)
        repository.finishLoad()
        _ = try await status.value
        _ = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(repository.loadCount, 3)
    }

    func testStatusRechecksCachedOwnershipAndDoesNotCacheConflicts() async throws {
        let repository = FakeRepository()
        let manager = ownedManager(owner: owner)
        repository.savedManagers = [manager]
        let client = makeClient(repository)
        _ = try await client.status(providerBundleIdentifier: provider)
        let metadata = try XCTUnwrap(manager.configuration as? NETunnelProviderProtocol)
        metadata.providerConfiguration?[WGCContract.ownerKey] = "dev.other.app"
        do { _ = try await client.status(providerBundleIdentifier: provider); XCTFail("Cached ownership must be checked") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        repository.savedManagers = [ownedManager(owner: owner), ownedManager(owner: owner)]
        do { _ = try await client.status(providerBundleIdentifier: provider); XCTFail("Duplicates must be rejected") }
        catch { XCTAssertEqual(error as? WGCNEError, .profileConflict) }
        repository.savedManagers.removeLast()
        _ = try await client.status(providerBundleIdentifier: provider)
        XCTAssertEqual(repository.loadCount, 4)
    }

    private func makeClient(_ repository: FakeRepository, _ store: FakeStore = FakeStore(),
                            operationTimeout: TimeInterval = 1, totalTimeout: TimeInterval = 2) -> WGCNEClient {
        WGCNEClient(owner: owner, repository: repository, store: store,
                    operationTimeout: operationTimeout, totalTimeout: totalTimeout)
    }

    private func start(_ client: WGCNEClient) async throws -> WGCStatus {
        try await client.start(providerBundleIdentifier: provider, keychainAccessGroup: group, configurationJSON: configuration)
    }

    private func ownedManager(owner: String, reference: Data = Data([1])) -> FakeManager {
        let manager = FakeManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = provider
        configuration.providerConfiguration = ProfileReference(reference: reference, accessGroup: group, owner: owner).dictionary
        manager.configuration = configuration
        return manager
    }

    private func profileReference(_ manager: FakeManager) throws -> ProfileReference {
        try ProfileReference(configuration: XCTUnwrap(manager.configuration as? NETunnelProviderProtocol))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Condition did not settle", file: file, line: line)
                throw WGCNEError.timeout
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private final class FakeRepository: TunnelManagerRepository {
    var savedManagers: [FakeManager] = [] {
        didSet { for manager in savedManagers { attach(manager) } }
    }
    private(set) var createdManagers: [FakeManager] = []
    private(set) var loadCount = 0
    var dropLoad = false
    var holdLoads = false
    var holdSaves = false
    var backgroundCallbacks = false
    private var loads: [([TunnelManagerHandle], @Sendable ([TunnelManagerHandle]?, Error?) -> Void)] = []
    var pendingLoadCount: Int { loads.count }

    func loadAll(_ completion: @escaping @Sendable ([TunnelManagerHandle]?, Error?) -> Void) {
        MainActor.preconditionIsolated()
        loadCount += 1
        guard !dropLoad else { return }
        if holdLoads { loads.append((savedManagers, completion)); return }
        deliver(savedManagers, to: completion)
    }

    func finishLoad() {
        let (snapshot, completion) = loads.removeFirst()
        deliver(snapshot, to: completion)
    }

    func makeManager() -> TunnelManagerHandle {
        MainActor.preconditionIsolated()
        let manager = FakeManager()
        manager.holdSave = holdSaves
        attach(manager)
        createdManagers.append(manager)
        return manager
    }

    private func attach(_ manager: FakeManager) {
        manager.backgroundCallbacks = backgroundCallbacks
        manager.didSave = { [weak self, weak manager] in
            guard let self, let manager else { return }
            if !self.savedManagers.contains(where: { $0 === manager }) { self.savedManagers.append(manager) }
        }
        manager.didRemove = { [weak self, weak manager] in
            guard let self, let manager else { return }
            self.savedManagers.removeAll { $0 === manager }
        }
    }

    private func deliver(_ managers: [TunnelManagerHandle],
                         to completion: @escaping @Sendable ([TunnelManagerHandle]?, Error?) -> Void) {
        if backgroundCallbacks { DispatchQueue.global().async { completion(managers, nil) } }
        else { completion(managers, nil) }
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
    var holdSave = false
    var holdRemove = false
    var backgroundCallbacks = false
    var didSave: (@MainActor () -> Void)?
    var didRemove: (@MainActor () -> Void)?
    var reply: Data?
    private(set) var sendCount = 0
    private var saves: [@Sendable (Error?) -> Void] = []
    private var removals: [@Sendable (Error?) -> Void] = []
    var pendingSaveCount: Int { saves.count }

    func save(_ completion: @escaping @Sendable (Error?) -> Void) {
        MainActor.preconditionIsolated()
        events.append("save")
        saves.append(completion)
        if !holdSave { finishSave() }
    }

    func finishSave(error: Error? = nil, duplicate: Bool = false) {
        let completion = saves.removeFirst()
        if error == nil { didSave?() }
        deliver(error, to: completion, duplicate: duplicate)
    }

    func reload(_ completion: @escaping @Sendable (Error?) -> Void) {
        MainActor.preconditionIsolated()
        events.append("reload")
        deliver(nil, to: completion)
    }

    func remove(_ completion: @escaping @Sendable (Error?) -> Void) {
        MainActor.preconditionIsolated()
        events.append("remove")
        removals.append(completion)
        if !holdRemove { finishRemove() }
    }

    func finishRemove(error: Error? = nil) {
        let completion = removals.removeFirst()
        if error == nil { didRemove?() }
        deliver(error, to: completion)
    }

    func start() throws { events.append("start"); currentStatus = .connecting }
    func stop() { events.append("stop"); currentStatus = .disconnected }

    func send(_ message: Data, completion: @escaping @Sendable (Data?) -> Void) throws {
        MainActor.preconditionIsolated()
        sendCount += 1
        guard let reply else { return }
        if backgroundCallbacks { DispatchQueue.global().async { completion(reply) } }
        else { completion(reply) }
    }

    private func deliver(_ error: Error?, to completion: @escaping @Sendable (Error?) -> Void, duplicate: Bool = false) {
        if backgroundCallbacks {
            DispatchQueue.global().async { completion(error); if duplicate { completion(error) } }
        } else {
            completion(error)
            if duplicate { completion(error) }
        }
    }
}

private final class ClientWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

private final class ClientLifetimePayload: Sendable {
    let configuration: String
    init(configuration: String) { self.configuration = configuration }
}

private final class FakeStore: ConfigurationStore, @unchecked Sendable {
    private let lock = NSLock()
    private let putGate: DispatchSemaphore?
    private let retainedPayload: ClientLifetimePayload?
    private var values: [Data: Data] = [:]
    private var deletes: [Data: Int] = [:]
    private var putBegan = false
    private var workWasOffMain = true

    init(holdPut: Bool = false, retaining payload: ClientLifetimePayload? = nil) {
        putGate = holdPut ? DispatchSemaphore(value: 0) : nil
        retainedPayload = payload
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var didBeginPut: Bool { lock.lock(); defer { lock.unlock() }; return putBegan }
    var totalDeletes: Int { lock.lock(); defer { lock.unlock() }; return deletes.values.reduce(0, +) }
    var allWorkWasOffMain: Bool { lock.lock(); defer { lock.unlock() }; return workWasOffMain }
    func releasePut() { putGate?.signal() }
    func deleteCount(_ reference: Data) -> Int { lock.lock(); defer { lock.unlock() }; return deletes[reference, default: 0] }

    func put(_ configuration: Data, accessGroup: String) throws -> Data {
        lock.lock()
        putBegan = true
        workWasOffMain = workWasOffMain && !Thread.isMainThread
        lock.unlock()
        putGate?.wait()
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
        lock.lock(); defer { lock.unlock() }
        workWasOffMain = workWasOffMain && !Thread.isMainThread
        deletes[reference, default: 0] += 1
        values.removeValue(forKey: reference)
    }
}
