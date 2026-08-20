import Foundation
import Testing
@testable import VVTerm

struct TerminalNetworkRecoveryGateTests {
    @Test
    func offlineCandidatesShareOneGenerationUntilNetworkIsReady() {
        var gate = TerminalNetworkRecoveryGate()

        guard case .wait(let generation) = gate.receive(
            .unavailable,
            shouldWait: true
        ) else {
            Issue.record("Expected an offline recovery generation")
            return
        }
        #expect(
            gate.receive(.unavailable, shouldWait: true) == .wait(generation)
        )
        #expect(
            gate.receive(.ready, shouldWait: false) == .resume(generation)
        )
        #expect(gate.receive(.ready, shouldWait: false) == .none)
    }

    @Test
    func offlineWithoutARecoveringPaneDoesNotCreateState() {
        var gate = TerminalNetworkRecoveryGate()

        #expect(gate.receive(.unavailable, shouldWait: false) == .none)
        #expect(gate.receive(.ready, shouldWait: false) == .none)
    }
}
