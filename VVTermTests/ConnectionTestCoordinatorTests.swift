import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ConnectionTestCoordinatorTests {

    @Test
    func isTestingSetDuringRun() async {
        let coordinator = ConnectionTestCoordinator()
        #expect(!coordinator.isTesting)

        let started = AsyncStream<Void>.makeStream()

        let task = Task {
            await coordinator.run {
                started.continuation.yield()
                started.continuation.finish()
                try await Task.sleep(for: .seconds(60))
            }
        }

        // Wait for the operation to actually start.
        for await _ in started.stream {}

        #expect(coordinator.isTesting)

        coordinator.cancel()
        _ = await task.value
        #expect(!coordinator.isTesting)
    }

    @Test
    func cancelStopsRunningTest() async {
        let coordinator = ConnectionTestCoordinator()

        let started = AsyncStream<Void>.makeStream()

        let task = Task {
            await coordinator.run {
                started.continuation.yield()
                started.continuation.finish()
                try await Task.sleep(for: .seconds(60))
            }
        }

        for await _ in started.stream {}

        coordinator.cancel()
        let result = await task.value
        #expect(result == nil)
        #expect(!coordinator.isTesting)
    }

    @Test
    func successfulRunReturnsSuccess() async {
        let coordinator = ConnectionTestCoordinator()

        let result = await coordinator.run {
            // Immediate success, no work needed.
        }

        #expect(!coordinator.isTesting)
        if case .success = result {
            // Expected
        } else {
            Issue.record("Expected .success, got \(String(describing: result))")
        }
    }

    @Test
    func failedRunReturnsFailure() async {
        let coordinator = ConnectionTestCoordinator()

        struct TestError: Error {}
        let result = await coordinator.run {
            throw TestError()
        }

        #expect(!coordinator.isTesting)
        if case .failure(let error) = result {
            #expect(error is TestError)
        } else {
            Issue.record("Expected .failure, got \(String(describing: result))")
        }
    }

    @Test
    func newRunCancelsPreviousRun() async {
        let coordinator = ConnectionTestCoordinator()

        let firstStarted = AsyncStream<Void>.makeStream()
        let secondCompleted = AsyncStream<Void>.makeStream()

        // Start a long-running first test.
        let firstTask = Task {
            await coordinator.run {
                firstStarted.continuation.yield()
                firstStarted.continuation.finish()
                try await Task.sleep(for: .seconds(60))
            }
        }

        for await _ in firstStarted.stream {}
        #expect(coordinator.isTesting)

        // Start a second test, which should supersede the first.
        let secondTask = Task {
            let result = await coordinator.run {
                // Completes immediately.
            }
            secondCompleted.continuation.yield()
            secondCompleted.continuation.finish()
            return result
        }

        for await _ in secondCompleted.stream {}

        // First run should return nil (superseded).
        let firstResult = await firstTask.value
        #expect(firstResult == nil)

        // Second run should succeed.
        let secondResult = await secondTask.value
        if case .success = secondResult {
            // Expected
        } else {
            Issue.record("Expected .success for second run, got \(String(describing: secondResult))")
        }

        #expect(!coordinator.isTesting)
    }

    @Test
    func cancelledRunDoesNotProduceCancellationErrorResult() async {
        let coordinator = ConnectionTestCoordinator()

        let started = AsyncStream<Void>.makeStream()

        let task = Task {
            await coordinator.run {
                started.continuation.yield()
                started.continuation.finish()
                try await Task.sleep(for: .seconds(60))
            }
        }

        for await _ in started.stream {}

        coordinator.cancel()
        let result = await task.value

        // Cancelled runs return nil, not .failure(CancellationError).
        #expect(result == nil)
    }

    @Test
    func cancelOnIdleCoordinatorIsHarmless() {
        let coordinator = ConnectionTestCoordinator()

        // Should not crash or change state.
        coordinator.cancel()
        #expect(!coordinator.isTesting)

        coordinator.cancel()
        #expect(!coordinator.isTesting)
    }
}
