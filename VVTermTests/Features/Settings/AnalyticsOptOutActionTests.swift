import Testing
@testable import VVTerm

@MainActor
struct AnalyticsOptOutActionTests {
    @Test
    func trueToFalseEmitsOnceBeforePersistence() {
        var enabled = true
        var events: [String] = []
        let action = AnalyticsOptOutAction(
            emitAnalyticsDisabled: {
                events.append("disabled while enabled: \(enabled)")
            }
        )
        let persist: (Bool) -> Void = { newValue in
            events.append("persist: \(newValue)")
            enabled = newValue
        }

        action.applyTransition(from: enabled, to: false, persist: persist)
        action.applyTransition(from: enabled, to: false, persist: persist)

        #expect(events == [
            "disabled while enabled: true",
            "persist: false",
            "persist: false"
        ])
    }

    @Test
    func enableAndNoOpTransitionsDoNotEmitDisabledEvent() {
        var disabledEventCount = 0
        var persistedValues: [Bool] = []
        let action = AnalyticsOptOutAction(
            emitAnalyticsDisabled: {
                disabledEventCount += 1
            }
        )

        action.applyTransition(from: false, to: true) {
            persistedValues.append($0)
        }
        action.applyTransition(from: true, to: true) {
            persistedValues.append($0)
        }
        action.applyTransition(from: false, to: false) {
            persistedValues.append($0)
        }

        #expect(disabledEventCount == 0)
        #expect(persistedValues == [true, true, false])
    }
}
