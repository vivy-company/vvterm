import Foundation

nonisolated final class CloudKitOperationContinuation<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?
    private var operation: Operation?
    private var result: Result<Success, Error>?
    private var cancelsOperation = false

    func install(_ continuation: CheckedContinuation<Success, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(_ operation: Operation) {
        lock.lock()
        let isComplete = result != nil
        if !isComplete {
            self.operation = operation
        }
        let shouldCancel = cancelsOperation
        lock.unlock()
        if shouldCancel {
            operation.cancel()
        }
    }

    func resume(returning value: Success) {
        complete(with: .success(value), cancellingOperation: false)
    }

    func resume(throwing error: Error) {
        complete(with: .failure(error), cancellingOperation: false)
    }

    func cancel() {
        complete(with: .failure(CancellationError()), cancellingOperation: true)
    }

    private func complete(
        with result: Result<Success, Error>,
        cancellingOperation: Bool
    ) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        cancelsOperation = cancellingOperation
        let continuation = self.continuation
        self.continuation = nil
        let operation = cancellingOperation ? self.operation : nil
        self.operation = nil
        lock.unlock()

        operation?.cancel()
        continuation?.resume(with: result)
    }
}

nonisolated final class CloudKitTaskContinuation<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?
    private var result: Result<Success, Error>?

    func install(_ continuation: CheckedContinuation<Success, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: Result<Success, Error>) {
        complete(with: result)
    }

    func cancel() {
        complete(with: .failure(CancellationError()))
    }

    private func complete(with result: Result<Success, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
