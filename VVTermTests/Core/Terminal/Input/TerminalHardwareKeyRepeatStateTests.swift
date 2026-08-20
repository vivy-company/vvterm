import Testing
@testable import VVTerm

struct TerminalHardwareKeyRepeatStateTests {
    @Test
    func startsRepeatingWithTokenizedPayload() {
        var state = TerminalHardwareKeyRepeatState<String>()

        let registration = state.register(
            keyCode: 11,
            payload: "h"
        )

        guard case .started(let active) = registration else {
            Issue.record("Expected a newly started repeat")
            return
        }
        #expect(active.keyCode == 11)
        #expect(active.payload == "h")
        #expect(state.active(for: active.token)?.keyCode == 11)
        #expect(state.active(for: active.token)?.payload == "h")
        guard case .repeating = state.phase else {
            Issue.record("Expected the repeating phase")
            return
        }
    }

    @Test
    func sameKeyUpdatesPayloadWithoutReplacingToken() {
        var state = TerminalHardwareKeyRepeatState<String>()
        let original = startedActive(
            from: state.register(keyCode: 11, payload: "h")
        )

        let registration = state.register(
            keyCode: 11,
            payload: "H"
        )

        guard case .updated(let active) = registration else {
            Issue.record("Expected the active repeat to be updated")
            return
        }
        #expect(active.token == original.token)
        #expect(state.active(for: original.token)?.payload == "H")
    }

    @Test
    func replacingKeyInvalidatesStaleToken() {
        var state = TerminalHardwareKeyRepeatState<String>()
        let original = startedActive(
            from: state.register(keyCode: 11, payload: "h")
        )

        let replacement = startedActive(
            from: state.register(keyCode: 12, payload: "i")
        )

        #expect(replacement.token != original.token)
        #expect(state.active(for: original.token) == nil)
        #expect(state.active(for: replacement.token)?.payload == "i")
    }

    @Test
    func unrelatedKeyEndDoesNotStopActiveRepeat() {
        var state = TerminalHardwareKeyRepeatState<String>()
        let active = startedActive(
            from: state.register(keyCode: 11, payload: "h")
        )

        let ended = state.end(keyCode: 12)

        #expect(ended == nil)
        #expect(state.active(for: active.token)?.keyCode == 11)
    }

    @Test
    func matchingKeyEndReturnsAndRemovesActiveRepeat() {
        var state = TerminalHardwareKeyRepeatState<String>()
        let active = startedActive(
            from: state.register(keyCode: 11, payload: "h")
        )

        let ended = state.end(keyCode: 11)

        #expect(ended?.token == active.token)
        #expect(state.active(for: active.token) == nil)
        guard case .idle = state.phase else {
            Issue.record("Expected the idle phase")
            return
        }
    }

    @Test
    func cancelReturnsAndRemovesActiveRepeat() {
        var state = TerminalHardwareKeyRepeatState<String>()
        let active = startedActive(
            from: state.register(
                keyCode: 11,
                payload: "h"
            )
        )

        let cancelled = state.cancel()

        #expect(cancelled?.token == active.token)
        #expect(state.active(for: active.token) == nil)
        #expect(state.cancel() == nil)
        guard case .idle = state.phase else {
            Issue.record("Expected the idle phase")
            return
        }
    }

    private func startedActive<Payload>(
        from registration: TerminalHardwareKeyRepeatState<Payload>.Registration
    ) -> TerminalHardwareKeyRepeatState<Payload>.Active {
        guard case .started(let active) = registration else {
            Issue.record("Expected a newly started repeat")
            fatalError("Test setup failed")
        }
        return active
    }
}
