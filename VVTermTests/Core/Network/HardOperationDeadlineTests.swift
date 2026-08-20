import Foundation
import Testing
@testable import VVTerm

private nonisolated final class DeadlineAbortCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

nonisolated final class DeadlineBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isReleased = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

struct HardOperationDeadlineTests {
    @Test
    func deadlineAbortsAndReturnsWithoutWaitingForBlockedOperation() async {
        let abortCounter = DeadlineAbortCounter()
        let blocker = DeadlineBlocker()
        let startedAt = ContinuousClock.now

        await #expect(throws: HardOperationDeadlineError.self) {
            try await HardOperationDeadline.run(
                timeout: .milliseconds(20),
                onTimeout: { abortCounter.increment() }
            ) {
                await blocker.wait()
            }
        }

        #expect(abortCounter.value == 1)
        #expect(startedAt.duration(to: .now) < .seconds(1))
        blocker.release()
        await Task.yield()
    }

    @Test
    func completedOperationCancelsDeadlineWithoutAborting() async throws {
        let abortCounter = DeadlineAbortCounter()

        let value = try await HardOperationDeadline.run(
            timeout: .seconds(1),
            onTimeout: { abortCounter.increment() }
        ) {
            42
        }

        #expect(value == 42)
        #expect(abortCounter.value == 0)
    }
}
