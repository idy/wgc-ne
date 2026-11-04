import Foundation

/// Bridges callback APIs without relying on the callback ever being delivered.
/// Late callbacks, cancellation, and timeout all compete for one continuation.
internal final class BoundedCallback<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var timeoutWork: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<Value, Error>, timeout: TimeInterval) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        let work = DispatchWorkItem { [weak self] in
            self?.resolve(.failure(WGCNEError.timeout))
        }
        timeoutWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout), execute: work)
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return false }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }
}

@MainActor
internal func boundedCallback<Value>(
    timeout: TimeInterval,
    _ operation: @MainActor (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
) async throws -> Value {
    let callback = BoundedCallback<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            callback.install(continuation, timeout: timeout)
            if !callback.isResolved {
                operation { callback.resolve($0) }
            }
        }
    } onCancel: {
        callback.resolve(.failure(WGCNEError.cancelled))
    }
}

@MainActor
internal func utilityOperation<Value>(
    timeout: TimeInterval,
    onLateSuccess: (@Sendable (Value) -> Void)? = nil,
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let callback = BoundedCallback<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            callback.install(continuation, timeout: timeout)
            if !callback.isResolved {
                DispatchQueue.global(qos: .utility).async {
                    let result = Result { try operation() }
                    // This worker completes once. A resource it could not deliver has
                    // never reached the caller and can be disposed here, even after
                    // that caller's task has been cancelled.
                    if !callback.resolve(result), case .success(let value) = result {
                        onLateSuccess?(value)
                    }
                }
            }
        }
    } onCancel: {
        callback.resolve(.failure(WGCNEError.cancelled))
    }
}
