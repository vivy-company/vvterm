#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct MacTerminalRecoveryUITestHarnessTests {
    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test
    func eightHourWakeCanReachConnectedOutcome() async {
        let model = MacTerminalRecoveryUITestHarnessModel(simulatesSuccess: true)

        model.run()

        #expect(await eventually { model.outcome == .connected })
        #expect(model.simulatedInterval == 8 * 60 * 60)
        #expect(model.lastAttemptStartedAt == Date(timeIntervalSince1970: 8 * 60 * 60))
        #expect(model.observedOutcomes.contains(.waitingForNetwork))
        #expect(model.cleanupCount == 1)
        #expect(model.replacementCount == 1)
    }

    @Test
    func eightHourWakeCanReachActionableFailureOutcome() async {
        let model = MacTerminalRecoveryUITestHarnessModel(simulatesSuccess: false)

        model.run()

        #expect(await eventually { model.outcome == .failed })
        #expect(model.simulatedInterval == 8 * 60 * 60)
        #expect(model.observedOutcomes.contains(.waitingForNetwork))
        #expect(model.cleanupCount == 2)
        #expect(model.replacementCount == 1)
    }
}
#endif
