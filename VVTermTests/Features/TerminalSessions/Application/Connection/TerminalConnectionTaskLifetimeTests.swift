import Foundation
import Testing
@testable import VVTerm

private actor TerminalConnectionTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if continuations.count >= count { return true }
            await Task.yield()
        }
        return continuations.count >= count
    }

    func resume(at index: Int) {
        continuations[index].resume()
    }
}

private final class TerminalConnectionTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

@Suite(.serialized)
@MainActor
struct TerminalConnectionTaskLifetimeTests {
    @Test
    func paneRemovalCancelsAndClosesOnceWithoutLateStateWrite() async {
        let store = TerminalConnectionTaskStore()
        let paneId = UUID()
        let gate = TerminalConnectionTestGate()
        let cancellations = TerminalConnectionTestCounter()
        let closes = TerminalConnectionTestCounter()
        let stateWrites = TerminalConnectionTestCounter()

        let taskId = store.start(for: paneId) { taskId in
            await withTaskCancellationHandler {
                await gate.wait()
                if await store.isCurrent(taskId: taskId, for: paneId) {
                    stateWrites.increment()
                }
            } onCancel: {
                cancellations.increment()
                closes.increment()
            }
        }
        #expect(taskId != nil)
        #expect(await gate.waitForCount(1))

        #expect(store.cancel(for: paneId))
        #expect(!store.cancel(for: paneId))
        await gate.resume(at: 0)

        for _ in 0..<2_000 where cancellations.value == 0 {
            await Task.yield()
        }
        #expect(cancellations.value == 1)
        #expect(closes.value == 1)
        #expect(stateWrites.value == 0)
    }

    @Test
    func replacementAndCancellationSuppressStaleWatchdogs() async {
        let gate = TerminalConnectionTestGate()
        let fires = TerminalConnectionTestCounter()
        let watchdog = TerminalConnectionWatchdog(
            delay: .seconds(20),
            sleep: { _ in await gate.wait() }
        )

        watchdog.replace { fires.increment() }
        #expect(await gate.waitForCount(1))
        watchdog.replace { fires.increment() }
        #expect(await gate.waitForCount(2))

        await gate.resume(at: 0)
        for _ in 0..<20 { await Task.yield() }
        #expect(fires.value == 0)

        await gate.resume(at: 1)
        for _ in 0..<2_000 where fires.value == 0 {
            await Task.yield()
        }
        #expect(fires.value == 1)

        watchdog.replace { fires.increment() }
        #expect(await gate.waitForCount(3))
        watchdog.cancel()
        await gate.resume(at: 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(fires.value == 1)
    }
}
