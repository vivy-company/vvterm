import Testing
@testable import VVTerm

struct TerminalLiveActivityPolicyTests {
    @Test
    func inactiveSessionsEndTheActivity() {
        let snapshot = TerminalLiveActivityPolicy.snapshot(
            for: [.disconnected, .failed(terminalExternalFailure("Timed out")), .idle]
        )

        #expect(snapshot == nil)
    }

    @Test
    func activeSessionCountExcludesInactiveSessions() {
        let snapshot = TerminalLiveActivityPolicy.snapshot(
            for: [.connected, .connecting, .disconnected, .failed(terminalExternalFailure("Closed"))]
        )

        #expect(
            snapshot == TerminalLiveActivitySnapshot(
                status: .connecting,
                activeCount: 2
            )
        )
    }

    @Test
    func reconnectingTakesStatusPrecedence() {
        let snapshot = TerminalLiveActivityPolicy.snapshot(
            for: [.connected, .connecting, .reconnecting(attempt: 2)]
        )

        #expect(
            snapshot == TerminalLiveActivitySnapshot(
                status: .reconnecting,
                activeCount: 3
            )
        )
    }

    @Test
    func connectedSessionStartsConnectedActivity() {
        let snapshot = TerminalLiveActivityPolicy.snapshot(for: [.connected])

        #expect(
            snapshot == TerminalLiveActivitySnapshot(
                status: .connected,
                activeCount: 1
            )
        )
    }
}
