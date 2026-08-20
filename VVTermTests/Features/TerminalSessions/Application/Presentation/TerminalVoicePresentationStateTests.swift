import Testing
@testable import VVTerm

struct TerminalVoicePresentationStateTests {
    @Test
    func recordingAndPendingReturnAreMutuallyExclusive() {
        let state = TerminalVoicePresentationState.recording
            .applying(.transcriptionSent)

        #expect(state == .pendingReturn)
        #expect(!state.isRecording)
        #expect(state.isPendingReturn)
    }

    @Test
    func lateRecordingStopDoesNotClearPendingReturn() {
        let state = TerminalVoicePresentationState.recording
            .applying(.transcriptionSent)
            .applying(.recordingStopped)

        #expect(state == .pendingReturn)
    }

    @Test
    func pendingReturnDismissalDoesNotStopRecording() {
        let state = TerminalVoicePresentationState.recording
            .applying(.pendingReturnDismissed)

        #expect(state == .recording)
    }

    @Test
    func recordingStopReturnsRecordingStateToIdle() {
        let state = TerminalVoicePresentationState.recording
            .applying(.recordingStopped)

        #expect(state == .idle)
    }
}
