import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct TerminalTransportWriteQueueTests {
    @Test
    @MainActor
    func preservesInputOrderWhenAnEarlierWriteSuspends() async {
        let queue = TerminalTransportWriteQueue()
        let recorder = TerminalTransportWriteRecorder()

        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(30))
            await recorder.append(1)
        }
        queue.enqueue {
            await recorder.append(2)
        }
        queue.enqueue {
            await recorder.append(3)
        }

        await queue.waitForPendingWrites()

        let values = await recorder.values
        #expect(values == [1, 2, 3])
    }

    @Test
    @MainActor
    func cancelDropsQueuedWriteBehindCancellationIgnoringOperation() async {
        let queue = TerminalTransportWriteQueue()
        let gate = TerminalTransportWriteGate()
        let recorder = TerminalTransportWriteRecorder()

        queue.enqueue {
            await gate.block()
            await recorder.append(1)
        }
        queue.enqueue {
            await recorder.append(2)
        }

        await gate.waitUntilBlocked()
        queue.cancel()
        await gate.release()
        await recorder.waitForCount(1)

        let values = await recorder.values
        #expect(values == [1])
    }
}

private actor TerminalTransportWriteRecorder {
    private(set) var values: [Int] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ value: Int) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.0 }
        countWaiters.removeAll { values.count >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}

private actor TerminalTransportWriteGate {
    private var blocked = false
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        let waiters = blockWaiters
        blockWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
