import Foundation
import MoshCore
import Testing
@testable import VVTerm

struct MoshStartupReadinessTests {
    @Test(arguments: [
        MoshHostOp.echoAck(1),
        .resize(cols: 80, rows: 24)
    ])
    func nonVisibleInboundOperationEstablishesTransport(_ operation: MoshHostOp) {
        #expect(
            MoshStartupReadiness.isTransportEstablished(by: [operation])
        )
    }

    @Test
    func officialEmptyAcknowledgementEstablishesTransport() {
        #expect(
            MoshStartupReadiness.isTransportEstablished(
                by: [.hostBytes(Data())]
            )
        )
    }

    @Test
    func readinessRequiresAnInboundOperation() {
        #expect(!MoshStartupReadiness.isTransportEstablished(by: []))
        #expect(
            MoshStartupReadiness.isTransportEstablished(
                by: [.hostBytes(Data("ready".utf8))]
            )
        )
    }

    @Test
    func visibleTerminalDataRemainsSeparateFromTransportReadiness() {
        #expect(MoshStartupReadiness.visibleTerminalBytes(from: .echoAck(1)) == nil)
        #expect(
            MoshStartupReadiness.visibleTerminalBytes(
                from: .resize(cols: 80, rows: 24)
            ) == nil
        )
        #expect(MoshStartupReadiness.visibleTerminalBytes(from: .hostBytes(Data())) == nil)
        #expect(
            MoshStartupReadiness.visibleTerminalBytes(
                from: .hostBytes(Data("visible".utf8))
            ) == Data("visible".utf8)
        )
    }

    @Test
    func readinessWaitPreservesDrainedOperations() async throws {
        let source = MoshHostOperationSource([
            [.resize(cols: 80, rows: 24), .echoAck(1)]
        ])

        let operations = try await withReadinessTimeout {
            try await SSHClient.waitForMoshTransportReadiness(
                pollInterval: .milliseconds(1)
            ) {
                await source.drain()
            }
        }

        #expect(operations == [.resize(cols: 80, rows: 24), .echoAck(1)])
    }

    @Test
    func readinessWaitRespondsToCancellation() async {
        let task = Task {
            try await SSHClient.waitForMoshTransportReadiness(
                pollInterval: .milliseconds(1)
            ) {
                []
            }
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func withReadinessTimeout(
        operation: @escaping @Sendable () async throws -> [MoshHostOp]
    ) async throws -> [MoshHostOp] {
        try await withThrowingTaskGroup(of: [MoshHostOp].self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw MoshStartupReadinessTestError.timeout
            }

            guard let result = try await group.next() else {
                throw MoshStartupReadinessTestError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

private actor MoshHostOperationSource {
    private var batches: [[MoshHostOp]]

    init(_ batches: [[MoshHostOp]]) {
        self.batches = batches
    }

    func drain() -> [MoshHostOp] {
        guard !batches.isEmpty else { return [] }
        return batches.removeFirst()
    }
}

private enum MoshStartupReadinessTestError: Error {
    case timeout
}
