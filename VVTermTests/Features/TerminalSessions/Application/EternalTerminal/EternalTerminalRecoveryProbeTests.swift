import Testing
@testable import VVTerm

struct EternalTerminalRecoveryProbeTests {
    @Test
    func onlyAConnectedEventObservedAfterProbeStartCanCompleteIt() {
        var probe = EternalTerminalRecoveryProbe()
        let eventBeforeProbe = probe.pendingID
        let probeID = probe.begin()

        probe.recordConnected(eventProbeID: eventBeforeProbe)
        #expect(!probe.didComplete(probeID))

        probe.recordConnected(eventProbeID: probe.pendingID)
        #expect(probe.didComplete(probeID))
    }

    @Test
    func resetRejectsLateConnectedEvent() {
        var probe = EternalTerminalRecoveryProbe()
        let probeID = probe.begin()
        let eventProbeID = probe.pendingID

        probe.reset()
        probe.recordConnected(eventProbeID: eventProbeID)

        #expect(!probe.didComplete(probeID))
    }
}
