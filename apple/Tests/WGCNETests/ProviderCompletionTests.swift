import Foundation
import XCTest
@testable import WGCNE

final class ProviderCompletionTests: XCTestCase {
    func testNilSuccessIsAValueAndCompletesOnce() {
        var errors: [Error?] = []
        let completion = ProviderErrorCompletion { errors.append($0) }
        completion.finish(nil)
        completion.finish(WGCNEError.cancelled)
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(errors[0])

        var replies: [Data?] = []
        let reply = ProviderCompletion<Data?> { replies.append($0) }
        reply.finish(nil)
        reply.finish(Data([1]))
        XCTAssertEqual(replies.count, 1)
        XCTAssertNil(replies[0])
    }

    func testFinishAndArmingAreReentrantOutsideTheLock() async {
        let finished = expectation(description: "reentrant completion")
        let timeoutEffect = expectation(description: "finished completions cannot arm a timeout")
        timeoutEffect.isInverted = true
        var completion: ProviderCompletion<Int>!
        completion = ProviderCompletion { value in
            XCTAssertEqual(value, 7)
            completion.finish(8)
            completion.armTimeout(0, value: 9, onTimeout: { timeoutEffect.fulfill() })
            finished.fulfill()
        }
        DispatchQueue.global().async(execute: DispatchWorkItem { completion.finish(7) })
        await fulfillment(of: [finished, timeoutEffect], timeout: 0.05)
    }

    func testTimeoutEffectWinsOnceAndCanReenterCompletion() async {
        let finished = expectation(description: "deadline completion")
        let values = CompletionTestValue<[Int]>([])
        let effects = CompletionTestValue(0)
        var completion: ProviderCompletion<Int>!
        completion = ProviderCompletion { value in
            values.update { $0.append(value) }
            finished.fulfill()
        }
        completion.armTimeout(0.01, value: 3, onTimeout: {
            effects.update { $0 += 1 }
            completion.finish(4)
            completion.armTimeout(0, value: 5)
        })
        await fulfillment(of: [finished], timeout: 1)
        completion.finish(6)
        XCTAssertEqual(values.value, [3])
        XCTAssertEqual(effects.value, 1)
    }

    func testFirstArmedDeadlineIsPreserved() async {
        let finished = expectation(description: "original deadline")
        let completion = ProviderCompletion<Int> { value in
            XCTAssertEqual(value, 1)
            finished.fulfill()
        }
        completion.armTimeout(0.02, value: 1)
        completion.armTimeout(0, value: 2)
        await fulfillment(of: [finished], timeout: 1)
    }

    func testConcurrentFinishAndTimeoutHaveOneWinnerAndMatchingEffects() async {
        let count = 100
        let finished = expectation(description: "all completion winners")
        finished.expectedFulfillmentCount = count
        let workersDone = expectation(description: "all finish and arm attempts")
        let results = CompletionTestValue(Array(repeating: [Int](), count: count))
        let effects = CompletionTestValue(Array(repeating: 0, count: count))
        let group = DispatchGroup()
        var completions: [ProviderCompletion<Int>] = []
        for index in 0..<count {
            let completion = ProviderCompletion<Int> { value in
                results.update { $0[index].append(value) }
                finished.fulfill()
            }
            completions.append(completion)
            for contender in 0..<8 {
                group.enter()
                DispatchQueue.global().async(execute: DispatchWorkItem {
                    if contender.isMultiple(of: 2) {
                        completion.armTimeout(0, value: -1, onTimeout: { effects.update { $0[index] += 1 } })
                    } else {
                        completion.finish(contender)
                    }
                    group.leave()
                })
            }
        }
        group.notify(queue: .global()) { workersDone.fulfill() }
        await fulfillment(of: [finished, workersDone], timeout: 3)
        withExtendedLifetime(completions) {
            let winners = results.value
            let timeoutEffects = effects.value
            for index in 0..<count {
                XCTAssertEqual(winners[index].count, 1)
                XCTAssertEqual(timeoutEffects[index], winners[index].first == -1 ? 1 : 0)
            }
        }
    }
}

private final class CompletionTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}
