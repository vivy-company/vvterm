import Foundation
import Testing
@testable import VVTerm

struct SSHOperationDeadlineTests {
    @Test
    func deadlineReturnsWhenOperationIgnoresCancellation() async {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await SSHClient.runWithDeadline(.milliseconds(50)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // Simulate a transport operation that ignores cancellation.
                }
                try? await Task.sleep(for: .milliseconds(500))
                return "late"
            }
            Issue.record("Expected the operation to time out")
        } catch SSHError.timeout {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(startedAt.duration(to: clock.now) < .milliseconds(300))
    }

    @Test
    func deadlineRunsTimeoutCleanupOnce() async {
        let counter = LockedCounter()

        do {
            _ = try await SSHClient.runWithDeadline(
                .milliseconds(20),
                onTimeout: { counter.increment() }
            ) {
                try? await Task.sleep(for: .seconds(1))
                return true
            }
            Issue.record("Expected the operation to time out")
        } catch SSHError.timeout {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(counter.value == 1)
    }
}

private nonisolated final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
