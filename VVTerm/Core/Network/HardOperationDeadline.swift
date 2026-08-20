import Foundation

nonisolated enum HardOperationDeadlineError: Error {
    case exceeded
}

private nonisolated final class HardOperationDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolvedResult: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let resolvedResult {
            lock.unlock()
            continuation.resume(with: resolvedResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func track(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if resolvedResult != nil {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    func resolve(
        _ result: Result<Value, Error>,
        beforeResuming: () -> Void = {}
    ) {
        lock.lock()
        guard resolvedResult == nil else {
            lock.unlock()
            return
        }
        resolvedResult = result
        let continuation = continuation
        let tasks = tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()

        beforeResuming()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

/// Returns at the deadline even when the operation ignores cooperative task
/// cancellation. The losing operation is cancelled but deliberately not awaited.
nonisolated enum HardOperationDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = HardOperationDeadlineRace<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)

                let operationTask = Task {
                    do {
                        race.resolve(.success(try await operation()))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let deadlineTask = Task {
                    do {
                        try await sleep(timeout)
                    } catch {
                        return
                    }
                    race.resolve(.failure(HardOperationDeadlineError.exceeded)) {
                        onTimeout()
                    }
                }
                race.track([operationTask, deadlineTask])
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}
