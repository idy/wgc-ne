import Foundation
import XCTest
@testable import WGCNE

final class BoundedCallbackTests: XCTestCase {
    func testMissingCallbackTimesOut() async {
        do {
            let _: Int = try await boundedCallback(timeout: 0.02) { _ in }
            XCTFail("An absent callback must time out")
        } catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
    }

    func testCancellationWinsAndLateCallbacksAreIgnored() async throws {
        let task = Task { () throws -> Int in
            try await boundedCallback(timeout: 2) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { completion(.success(9)) }
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not succeed") }
        catch { XCTAssertEqual(error as? WGCNEError, .cancelled) }
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    func testDuplicateCallbackCompletesOnce() async throws {
        let result: Int = try await boundedCallback(timeout: 1) { completion in
            completion(.success(3))
            completion(.success(4))
        }
        XCTAssertEqual(result, 3)
    }

    func testRegistrationRunsOnMainActorFromDetachedTask() async throws {
        let task = Task.detached {
            try await boundedCallback(timeout: 1) { completion in
                MainActor.preconditionIsolated()
                dispatchPrecondition(condition: .onQueue(.main))
                completion(.success(Thread.isMainThread))
            }
        }
        let registeredOnMain = try await task.value
        XCTAssertTrue(registeredOnMain)
    }

    func testUtilityWorkRunsOffMainFromMainActorRegistration() async throws {
        let ranOnMain = try await Task.detached {
            try await utilityOperation(timeout: 1) {
                dispatchPrecondition(condition: .notOnQueue(.main))
                return Thread.isMainThread
            }
        }.value
        XCTAssertFalse(ranOnMain)
    }

    func testUtilityLateSuccessDisposalRunsOnceOffMainAfterTimeout() async throws {
        let began = expectation(description: "Utility work began")
        let disposed = expectation(description: "Undelivered result disposed")
        disposed.assertForOverFulfill = true
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            try await utilityOperation(timeout: 0.03, onLateSuccess: { value in
                dispatchPrecondition(condition: .notOnQueue(.main))
                XCTAssertEqual(value, 17)
                disposed.fulfill()
            }) {
                began.fulfill()
                gate.wait()
                return 17
            }
        }
        await fulfillment(of: [began], timeout: 1)
        do { _ = try await task.value; XCTFail("Held work must time out") }
        catch { XCTAssertEqual(error as? WGCNEError, .timeout) }
        gate.signal()
        await fulfillment(of: [disposed], timeout: 1)
    }

    func testProviderCancellationCompletionIsExactlyOnce() {
        var values: [WGCNEError?] = []
        let completion = ProviderErrorCompletion { values.append($0 as? WGCNEError) }
        completion.finish(WGCNEError.cancelled)
        completion.finish(nil)
        completion.finish(WGCNEError.timeout)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first!, .cancelled)
    }
}
