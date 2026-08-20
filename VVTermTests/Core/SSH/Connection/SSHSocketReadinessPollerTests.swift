import Darwin
import Foundation
import Testing
@testable import VVTerm

@Suite
struct SSHSocketReadinessPollerTests {
    @Test
    func readySocketResumesBeforeDeadline() async throws {
        let pair = try SocketPair()
        let poller = SSHSocketReadinessPoller(label: "test.ssh-readiness.ready")

        let wait = Task {
            await poller.wait(
                fileDescriptor: pair.readDescriptor,
                events: Int16(POLLIN),
                timeoutMilliseconds: 500
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        try pair.signal()

        let startedAt = ContinuousClock.now
        await wait.value
        #expect(ContinuousClock.now - startedAt < .milliseconds(100))
    }

    @Test
    func cancellationResumesWaiter() async throws {
        let pair = try SocketPair()
        let poller = SSHSocketReadinessPoller(label: "test.ssh-readiness.cancel")
        let wait = Task {
            await poller.wait(
                fileDescriptor: pair.readDescriptor,
                events: Int16(POLLIN),
                timeoutMilliseconds: 1_000
            )
        }

        try await Task.sleep(for: .milliseconds(10))
        let startedAt = ContinuousClock.now
        wait.cancel()
        await wait.value

        #expect(ContinuousClock.now - startedAt < .milliseconds(100))
    }

    @Test
    func manySessionWaitsShareOneBoundedPollWindow() async throws {
        let sessionCount = 128
        let pairs = try (0..<sessionCount).map { _ in try SocketPair() }
        let poller = SSHSocketReadinessPoller(label: "test.ssh-readiness.many")
        let startedAt = ContinuousClock.now

        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask {
                    await poller.wait(
                        fileDescriptor: pair.readDescriptor,
                        events: Int16(POLLIN),
                        timeoutMilliseconds: 10
                    )
                }
            }
        }

        let elapsed = ContinuousClock.now - startedAt
        print("DEV334 socket-readiness sessions=\(sessionCount) elapsed=\(elapsed)")
        #expect(elapsed < .milliseconds(250))
    }

    @Test
    func manySessionBenchmarkReportsBeforeAndAfterMedianAndTail() async throws {
        let sampleCount = 7
        let sessionCount = 64
        let timeoutMilliseconds: Int32 = 5
        let pairs = try (0..<sessionCount).map { _ in try SocketPair() }
        var synchronousSamples: [Duration] = []
        var coalescedSamples: [Duration] = []
        synchronousSamples.reserveCapacity(sampleCount)
        coalescedSamples.reserveCapacity(sampleCount)

        for sample in 0..<sampleCount {
            synchronousSamples.append(
                await measureSynchronousWaits(
                    pairs: pairs,
                    timeoutMilliseconds: timeoutMilliseconds
                )
            )
            coalescedSamples.append(
                await measureCoalescedWaits(
                    pairs: pairs,
                    timeoutMilliseconds: timeoutMilliseconds,
                    sample: sample
                )
            )
        }

        let beforeMedian = percentile(50, samples: synchronousSamples)
        let beforeTail = percentile(95, samples: synchronousSamples)
        let afterMedian = percentile(50, samples: coalescedSamples)
        let afterTail = percentile(95, samples: coalescedSamples)
        print(
            "DEV334 socket-readiness sessions=\(sessionCount) "
                + "beforeMedianMs=\(milliseconds(beforeMedian)) "
                + "beforeP95Ms=\(milliseconds(beforeTail)) "
                + "afterMedianMs=\(milliseconds(afterMedian)) "
                + "afterP95Ms=\(milliseconds(afterTail))"
        )

        #expect(afterTail < beforeMedian)
    }

    private func measureSynchronousWaits(
        pairs: [SocketPair],
        timeoutMilliseconds: Int32
    ) async -> Duration {
        let startedAt = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask {
                    var descriptor = pollfd(
                        fd: pair.readDescriptor,
                        events: Int16(POLLIN),
                        revents: 0
                    )
                    _ = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
                }
            }
        }
        return ContinuousClock.now - startedAt
    }

    private func measureCoalescedWaits(
        pairs: [SocketPair],
        timeoutMilliseconds: Int32,
        sample: Int
    ) async -> Duration {
        let poller = SSHSocketReadinessPoller(
            label: "test.ssh-readiness.benchmark.\(sample)"
        )
        let startedAt = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask {
                    await poller.wait(
                        fileDescriptor: pair.readDescriptor,
                        events: Int16(POLLIN),
                        timeoutMilliseconds: timeoutMilliseconds
                    )
                }
            }
        }
        return ContinuousClock.now - startedAt
    }

    private func percentile(_ percentile: Int, samples: [Duration]) -> Duration {
        let sorted = samples.sorted()
        precondition(!sorted.isEmpty)
        let boundedPercentile = min(max(percentile, 0), 100)
        let rank = Double(sorted.count - 1) * Double(boundedPercentile) / 100
        let index = Int(rank.rounded(.up))
        return sorted[index]
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private nonisolated final class SocketPair: @unchecked Sendable {
    let readDescriptor: Int32
    private let writeDescriptor: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SocketPairError.creationFailed(errno)
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    deinit {
        Darwin.close(readDescriptor)
        Darwin.close(writeDescriptor)
    }

    func signal() throws {
        var byte: UInt8 = 1
        guard Darwin.write(writeDescriptor, &byte, 1) == 1 else {
            throw SocketPairError.writeFailed(errno)
        }
    }
}

private nonisolated enum SocketPairError: Error {
    case creationFailed(Int32)
    case writeFailed(Int32)
}
