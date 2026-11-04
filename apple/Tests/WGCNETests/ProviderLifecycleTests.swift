import Darwin
import Foundation
import NetworkExtension
import XCTest
@testable import WGCNE

final class ProviderLifecycleTests: XCTestCase {
    func testWatchdogStopsAndCancelsWithoutHostMessages() async {
        let fixture = ProviderFixture()
        await start(fixture)
        fixture.engines[0].setStatus(.success(try! WGCCoreStatus(state: "stopped")))
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
        fixture.settings.complete(1)
        await fulfillment(of: [fixture.cancelled], timeout: 2)
        let stopped = expectation(description: "stop after watchdog cancellation")
        fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertEqual(fixture.engines[0].startCount, 1)
        XCTAssertGreaterThan(fixture.engines[0].statusCount, 0)
        XCTAssertEqual(fixture.settings.kinds, ["apply", "clear"])
        XCTAssertEqual(fixture.cancellations.value.map { $0 as? WGCNEError }, [.coreFailure])
        let events = fixture.events.value
        XCTAssertLessThan(events.firstIndex(of: "0.stop")!, events.firstIndex(of: "clear")!)
        XCTAssertLessThan(events.firstIndex(of: "clear")!, events.firstIndex(of: "cancel")!)
    }

    func testStatusFailureAndExplicitStopsCancelAndCleanUpOnce() async {
        let fixture = ProviderFixture()
        await start(fixture)
        fixture.engines[0].setStatus(.failure(NSError(domain: "secret-transport-configuration", code: 7)))
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        let stopped = expectation(description: "both stop callers finish at the clear deadline")
        stopped.expectedFulfillmentCount = 2
        for _ in 0..<2 { fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() } }
        await fulfillment(of: [stopped, fixture.cancelled], timeout: 2)
        await assertStartRejected(fixture.provider)
        XCTAssertEqual(fixture.cancellations.value.map { $0 as? WGCNEError }, [.coreFailure])
        XCTAssertFalse(fixture.cancellations.value.first?.localizedDescription.contains("secret") ?? false)
        fixture.settings.complete(1)
        fixture.settings.complete(1)
        _ = await statusReply(fixture.provider)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
        XCTAssertEqual(fixture.cancellations.value.count, 1)
        XCTAssertEqual(fixture.settings.kinds, ["apply", "clear"])
    }

    func testExplicitStopWinsWhileWatchdogStatusIsInFlight() async {
        let fixture = ProviderFixture()
        let entered = expectation(description: "watchdog is reading status")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.engines[0].setStatusOperation {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            throw NSError(domain: "secret-status-failure", code: 1)
        }
        await start(fixture)
        await fulfillment(of: [entered], timeout: 2)
        let stopped = expectation(description: "coalesced explicit stops")
        stopped.expectedFulfillmentCount = 2
        for _ in 0..<2 { fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() } }
        release.signal()
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        fixture.settings.complete(1)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
        XCTAssertEqual(fixture.engines[0].statusCount, 1)
        XCTAssertTrue(fixture.cancellations.value.isEmpty)
        XCTAssertEqual(fixture.settings.kinds, ["apply", "clear"])
    }

    func testApplyAndClearDeadlinesKeepOwnershipUntilActualCallbacks() async {
        let fixture = ProviderFixture(engineCount: 2,
            timing: ProviderTiming(applySettings: 0.03, clearSettings: 0.03, reply: 0.1, start: 1, healthCheck: 0.01))
        let started = expectation(description: "apply deadline finishes start")
        let startResults = ProviderTestValue<[WGCNEError?]>([])
        fixture.provider.startTunnel { error in
            startResults.update { $0.append(error as? WGCNEError) }
            started.fulfill()
        }
        await fulfillment(of: [fixture.settings.expectCall(0), started], timeout: 2)
        XCTAssertEqual(startResults.value, [.timeout])
        let stopped = expectation(description: "stop remains bounded while the raw apply is pending")
        fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 2)
        await assertStartRejected(fixture.provider)
        XCTAssertEqual(fixture.settings.kinds, ["apply"])
        XCTAssertEqual(fixture.engines[0].startCount, 0)
        XCTAssertEqual(fixture.engines[0].stopCount, 0)

        fixture.settings.complete(0)
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        XCTAssertEqual(fixture.engines[0].startCount, 0)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
        let clearTimedOut = expectation(description: "clear deadline bounds another stop")
        fixture.provider.stopTunnel(with: .userInitiated) { clearTimedOut.fulfill() }
        await fulfillment(of: [clearTimedOut], timeout: 2)
        await assertStartRejected(fixture.provider)
        XCTAssertEqual(fixture.settings.kinds, ["apply", "clear"])

        fixture.settings.complete(1)
        _ = await statusReply(fixture.provider)
        await start(fixture, applyIndex: 2)
        // NE may deliver duplicate/late old callbacks, but they cannot affect the new run.
        fixture.settings.complete(0)
        fixture.settings.complete(1)
        let response = await statusReply(fixture.provider)
        let object = response.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual((object?["result"] as? [String: Any])?["state"] as? String, "running")
        XCTAssertEqual(startResults.value, [.timeout])
        XCTAssertEqual(fixture.engines[1].startCount, 1)
        XCTAssertEqual(fixture.engines[1].stopCount, 0)
        XCTAssertTrue(fixture.cancellations.value.isEmpty)
        XCTAssertEqual(fixture.settings.kinds, ["apply", "clear", "apply"])
        await stop(fixture, clearIndex: 3)
    }

    func testSuccessfulRunRetainsClearOwnershipPastDeadline() async {
        let fixture = ProviderFixture(engineCount: 2)
        await start(fixture)
        let stopped = expectation(description: "stop completes at the clear deadline")
        fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() }
        await fulfillment(of: [fixture.settings.expectCall(1), stopped], timeout: 2)
        await assertStartRejected(fixture.provider)
        XCTAssertEqual(fixture.settings.kinds, ["apply", "clear"])
        fixture.settings.complete(1)
        _ = await statusReply(fixture.provider)
        await start(fixture, applyIndex: 2)
        fixture.settings.complete(1, error: NSError(domain: "late-old-clear", code: 1))
        _ = await statusReply(fixture.provider)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
        XCTAssertEqual(fixture.engines[1].stopCount, 0)
        XCTAssertTrue(fixture.cancellations.value.isEmpty)
        await stop(fixture, clearIndex: 3)
    }

    func testOverallStartDeadlineCancelsBeforeLateActualApply() async {
        let fixture = ProviderFixture(timing:
            ProviderTiming(applySettings: 0.3, clearSettings: 0.03, reply: 0.1, start: 0.03, healthCheck: 0.01))
        let started = expectation(description: "overall start deadline")
        let results = ProviderTestValue<[WGCNEError?]>([])
        fixture.provider.startTunnel { error in
            results.update { $0.append(error as? WGCNEError) }
            started.fulfill()
        }
        await fulfillment(of: [fixture.settings.expectCall(0), started], timeout: 2)
        fixture.settings.complete(0)
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        fixture.settings.complete(1)
        _ = await statusReply(fixture.provider)
        XCTAssertEqual(results.value, [.timeout])
        XCTAssertEqual(fixture.engines[0].startCount, 0)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
    }

    func testStopDuringDescriptorLookupClosesDuplicateWithoutStartingCore() async {
        let entered = expectation(description: "descriptor lookup")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let descriptor = ProviderTestValue<Int32>(-1)
        let fixture = ProviderFixture(descriptor: { _ in
            let owned = open("/dev/null", O_RDONLY)
            descriptor.update { $0 = owned }
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            return owned
        })
        let started = expectation(description: "cancelled start")
        fixture.provider.startTunnel { error in
            XCTAssertEqual(error as? WGCNEError, .cancelled)
            started.fulfill()
        }
        await fulfillment(of: [fixture.settings.expectCall(0)], timeout: 2)
        fixture.settings.complete(0)
        await fulfillment(of: [entered], timeout: 2)
        let stopped = expectation(description: "stop after lookup settles")
        fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() }
        release.signal()
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        fixture.settings.complete(1)
        await fulfillment(of: [started, stopped], timeout: 2)
        XCTAssertGreaterThanOrEqual(descriptor.value, 0)
        XCTAssertEqual(fcntl(descriptor.value, F_GETFD), -1)
        XCTAssertEqual(fixture.engines[0].startCount, 0)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
    }

    func testReplyDeadlineIgnoresLateStatusAndRedactsErrors() async {
        let fixture = ProviderFixture(timing:
            ProviderTiming(applySettings: 0.5, clearSettings: 0.05, reply: 0.02, start: 1, healthCheck: 10))
        await start(fixture)
        let entered = expectation(description: "status message is in flight")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.engines[0].setStatusOperation {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            throw NSError(domain: "secret-status", code: 1)
        }
        let replied = expectation(description: "bounded provider reply")
        let replies = ProviderTestValue<[Data?]>([])
        fixture.provider.handleAppMessage(Data("{\"method\":\"status\"}".utf8)) { data in
            replies.update { $0.append(data) }
            replied.fulfill()
        }
        await fulfillment(of: [entered, replied], timeout: 2)
        guard let data = replies.value.first ?? nil else { XCTFail("Missing provider reply"); return }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((object?["error"] as? [String: String])?["code"], "timeout")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        let stopped = expectation(description: "stop after late status")
        fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() }
        release.signal()
        await fulfillment(of: [fixture.settings.expectCall(1)], timeout: 2)
        fixture.settings.complete(1)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(replies.value.count, 1)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
    }

    func testRawApplyErrorIsRedactedAndNeverStartsCore() async {
        let fixture = ProviderFixture()
        let started = expectation(description: "raw apply failure")
        fixture.provider.startTunnel { error in
            XCTAssertEqual(error as? WGCNEError, .tunnelStartFailed)
            XCTAssertFalse(error!.localizedDescription.contains("secret"))
            started.fulfill()
        }
        await fulfillment(of: [fixture.settings.expectCall(0)], timeout: 2)
        fixture.settings.complete(0, error: NSError(domain: "secret-settings", code: 1))
        await fulfillment(of: [started, fixture.settings.expectCall(1)], timeout: 2)
        fixture.settings.complete(1)
        _ = await statusReply(fixture.provider)
        XCTAssertEqual(fixture.engines[0].startCount, 0)
        XCTAssertEqual(fixture.engines[0].stopCount, 1)
        XCTAssertTrue(fixture.cancellations.value.isEmpty)
    }

    private func start(_ fixture: ProviderFixture, applyIndex: Int = 0) async {
        let started = expectation(description: "successful start \(applyIndex)")
        fixture.provider.startTunnel { error in XCTAssertNil(error); started.fulfill() }
        await fulfillment(of: [fixture.settings.expectCall(applyIndex)], timeout: 2)
        fixture.settings.complete(applyIndex)
        await fulfillment(of: [started], timeout: 2)
    }

    private func stop(_ fixture: ProviderFixture, clearIndex: Int) async {
        let stopped = expectation(description: "successful stop \(clearIndex)")
        fixture.provider.stopTunnel(with: .userInitiated) { stopped.fulfill() }
        await fulfillment(of: [fixture.settings.expectCall(clearIndex)], timeout: 2)
        fixture.settings.complete(clearIndex)
        await fulfillment(of: [stopped], timeout: 2)
    }

    private func assertStartRejected(_ provider: ProviderLifecycle) async {
        let rejected = expectation(description: "pending settings retain the current run")
        provider.startTunnel { error in
            XCTAssertEqual(error as? WGCNEError, .tunnelStartFailed)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
    }

    private func statusReply(_ provider: ProviderLifecycle) async -> Data? {
        let replied = expectation(description: "worker status reply")
        let result = ProviderTestValue<Data?>(nil)
        provider.handleAppMessage(Data("{\"method\":\"status\"}".utf8)) { data in
            result.update { $0 = data }
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 2)
        return result.value
    }
}

private final class ProviderFixture {
    let provider: ProviderLifecycle
    let engines: [ProviderTestEngine]
    let settings: ProviderTestSettings
    let events: ProviderTestValue<[String]>
    let cancellations: ProviderTestValue<[Error]>
    let cancelled: XCTestExpectation

    init(engineCount: Int = 1,
         timing: ProviderTiming = ProviderTiming(applySettings: 0.5, clearSettings: 0.05, reply: 0.1,
                                                start: 1, healthCheck: 0.01),
         descriptor: ((WGCNetworkSettings) throws -> Int32)? = nil) {
        let events = ProviderTestValue<[String]>([])
        let settings = ProviderTestSettings(events: events)
        let engines = (0..<engineCount).map { ProviderTestEngine(name: String($0), events: events) }
        let remaining = ProviderTestValue(engines)
        let cancellations = ProviderTestValue<[Error]>([])
        let cancelled = XCTestExpectation(description: "provider cancels the tunnel")
        let profile = NETunnelProviderProtocol()
        profile.providerConfiguration = [
            WGCContract.referenceKey: Data([1]), WGCContract.accessGroupKey: "TEAMID.dev.idy.test",
            WGCContract.ownerKey: "dev.idy.test"
        ]
        let operations = ProviderOperations(
            profile: { profile },
            makeCoreEngine: {
                guard let engine = remaining.modify({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                    throw WGCNEError.coreUnavailable
                }
                return engine
            },
            duplicateDescriptor: { settings in
                events.update { $0.append("descriptor") }
                if let descriptor { return try descriptor(settings) }
                let owned = open("/dev/null", O_RDONLY)
                guard owned >= 0 else { throw WGCNEError.tunnelUnavailable }
                return owned
            },
            setSettings: { settings.apply($0, completion: $1) },
            cancelTunnel: { error in
                events.update { $0.append("cancel") }
                cancellations.update { $0.append(error) }
                cancelled.fulfill()
            })
        let provider = ProviderLifecycle(store: ProviderTestStore(), operations: operations, timing: timing)
        self.provider = provider
        self.engines = engines
        self.settings = settings
        self.events = events
        self.cancellations = cancellations
        self.cancelled = cancelled
    }
}

private final class ProviderTestStore: ConfigurationStore {
    func read(reference: Data, accessGroup: String) throws -> Data { Data("synthetic-configuration".utf8) }
    func put(_ configuration: Data, accessGroup: String) throws -> Data { throw WGCNEError.keychainFailure }
    func delete(reference: Data, accessGroup: String) throws { throw WGCNEError.keychainFailure }
}

private final class ProviderTestEngine: CoreEngine {
    private struct State {
        var starts = 0
        var stops = 0
        var statuses = 0
        var status: Result<WGCCoreStatus, Error> = .success(try! WGCCoreStatus(state: "running"))
        var statusOperation: (() throws -> WGCCoreStatus)?
    }
    private let state = ProviderTestValue(State())
    private let name: String
    private let events: ProviderTestValue<[String]>
    init(name: String, events: ProviderTestValue<[String]>) { self.name = name; self.events = events }
    var startCount: Int { state.value.starts }
    var stopCount: Int { state.value.stops }
    var statusCount: Int { state.value.statuses }
    func setStatus(_ status: Result<WGCCoreStatus, Error>) { state.update { $0.status = status } }
    func setStatusOperation(_ operation: @escaping () throws -> WGCCoreStatus) { state.update { $0.statusOperation = operation } }
    func validate(configuration: Data) throws -> WGCNetworkSettings {
        events.update { $0.append("\(name).validate") }
        return try WGCNetworkSettings(addresses: ["10.7.0.2/32"], mtu: 1280,
            dnsServers: ["198.18.0.2"], includedRoutes: ["0.0.0.0/0"], excludedRoutes: [])
    }
    func start(ownedFileDescriptor: Int32, configuration: Data) throws {
        defer { close(ownedFileDescriptor) }
        state.update { $0.starts += 1 }
        events.update { $0.append("\(name).start") }
    }
    func status() throws -> WGCCoreStatus {
        let snapshot = state.modify { state in state.statuses += 1; return state }
        events.update { $0.append("\(name).status") }
        if let operation = snapshot.statusOperation { return try operation() }
        return try snapshot.status.get()
    }
    func stop() {
        state.update { $0.stops += 1 }
        events.update { $0.append("\(name).stop") }
    }
}

private final class ProviderTestSettings {
    private struct Call {
        let kind: String
        let completion: (Error?) -> Void
    }
    private struct State {
        var calls: [Call] = []
        var expectations: [Int: [XCTestExpectation]] = [:]
    }
    private let state = ProviderTestValue(State())
    private let events: ProviderTestValue<[String]>
    init(events: ProviderTestValue<[String]>) { self.events = events }
    var kinds: [String] { state.value.calls.map(\.kind) }
    func expectCall(_ index: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "settings operation \(index)")
        let alreadyCalled = state.modify { state in
            if state.calls.count > index { return true }
            state.expectations[index, default: []].append(expectation)
            return false
        }
        if alreadyCalled { expectation.fulfill() }
        return expectation
    }
    func apply(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping (Error?) -> Void) {
        let kind = settings == nil ? "clear" : "apply"
        events.update { $0.append(kind) }
        let expectations = state.modify { state in
            let index = state.calls.count
            state.calls.append(Call(kind: kind, completion: completion))
            return state.expectations.removeValue(forKey: index) ?? []
        }
        expectations.forEach { $0.fulfill() }
    }
    func complete(_ index: Int, error: Error? = nil) {
        let calls = state.value.calls
        guard calls.indices.contains(index) else { XCTFail("Missing settings operation \(index)"); return }
        events.update { $0.append("\(calls[index].kind).callback") }
        calls[index].completion(error)
    }
}

private final class ProviderTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { modify { $0 } }
    func update(_ body: (inout Value) -> Void) { modify(body) }
    func modify<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
