import Combine
import Foundation

/// Manages the lifecycle of a connection test task.
///
/// Owns the running `Task` handle so that callers can cancel an in-flight
/// test (e.g. when saving the server form) without leaking detached work.
@MainActor
final class ConnectionTestCoordinator: ObservableObject {

    @Published private(set) var isTesting = false

    private var task: Task<Result<Void, Error>, Never>?
    private var generation: UInt = 0

    // MARK: - Public API

    func cancel() {
        task?.cancel()
        task = nil
        if isTesting { isTesting = false }
        generation &+= 1
    }

    /// Run *operation* as a connection test on a detached task.
    ///
    /// - Returns: `.success` / `.failure` when the operation finishes,
    ///   or `nil` when the run was superseded by another `run()` or `cancel()`.
    @discardableResult
    func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async -> Result<Void, Error>? {
        // Cancel any in-flight test before starting a new one.
        task?.cancel()
        task = nil
        generation &+= 1
        let expectedGeneration = generation
        isTesting = true

        let detachedTask = Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        task = detachedTask

        let result = await detachedTask.value

        // Another run() or cancel() was called while we were waiting.
        guard generation == expectedGeneration else { return nil }

        isTesting = false
        task = nil
        return result
    }
}
