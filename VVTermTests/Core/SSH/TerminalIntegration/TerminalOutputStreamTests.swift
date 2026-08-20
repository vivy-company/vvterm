import Foundation
import Testing
@testable import VVTerm

struct TerminalOutputStreamTests {
    @Test
    func slowConsumerAppliesByteBackpressureWithoutDroppingData() async {
        let channel = TerminalOutputChannel(
            maximumQueuedBytes: 4,
            maximumQueuedItems: 2,
            maximumItemBytes: 4
        )
        #expect(await channel.send(Data([1, 2])))
        #expect(await channel.send(Data([3, 4])))

        let blockedSend = Task {
            await channel.send(Data([5, 6]))
        }
        await Task.yield()

        #expect(
            await channel.snapshot()
                == TerminalOutputChannel.Snapshot(
                    queuedBytes: 4,
                    queuedItems: 2,
                    pendingSends: 1
                )
        )

        var iterator = TerminalOutputStream(channel: channel).makeAsyncIterator()
        #expect(await iterator.next() == Data([1, 2]))
        #expect(await blockedSend.value)
        #expect(await iterator.next() == Data([3, 4]))
        #expect(await iterator.next() == Data([5, 6]))
    }

    @Test
    func finishDrainsQueuedDataInOrder() async {
        let channel = TerminalOutputChannel(
            maximumQueuedBytes: 8,
            maximumQueuedItems: 4,
            maximumItemBytes: 4
        )
        #expect(await channel.send(Data([1, 2, 3, 4, 5])))
        await channel.finish()

        var received: [UInt8] = []
        for await data in TerminalOutputStream(channel: channel) {
            received.append(contentsOf: data)
        }

        #expect(received == [1, 2, 3, 4, 5])
    }

    @Test
    func cancellationUnblocksSuspendedProducer() async {
        let channel = TerminalOutputChannel(
            maximumQueuedBytes: 2,
            maximumQueuedItems: 1,
            maximumItemBytes: 2
        )
        #expect(await channel.send(Data([1, 2])))

        let blockedSend = Task {
            await channel.send(Data([3]))
        }
        await Task.yield()
        #expect(await channel.snapshot().pendingSends == 1)

        await channel.cancel()

        #expect(!(await blockedSend.value))
        #expect(await channel.snapshot().queuedBytes == 0)
    }

    @Test
    func rejectPolicyFailsInsteadOfBufferingBeyondTheLimit() async {
        let channel = TerminalOutputChannel(
            maximumQueuedBytes: 2,
            maximumQueuedItems: 1,
            maximumItemBytes: 2,
            overflowPolicy: .rejectNewData
        )
        #expect(await channel.send(Data([1, 2])))

        #expect(!(await channel.send(Data([3]))))
        #expect(
            await channel.snapshot()
                == TerminalOutputChannel.Snapshot(
                    queuedBytes: 2,
                    queuedItems: 1,
                    pendingSends: 0
                )
        )
    }

    @Test
    func rejectPolicyRejectsAnOversizedItemWithoutPartialDelivery() async {
        let channel = TerminalOutputChannel(
            maximumQueuedBytes: 2,
            maximumQueuedItems: 2,
            maximumItemBytes: 1,
            overflowPolicy: .rejectNewData
        )

        #expect(!(await channel.send(Data([1, 2, 3]))))
        #expect(await channel.snapshot().queuedBytes == 0)
    }
}
