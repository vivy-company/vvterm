import Testing
@testable import VVTerm

struct ShellTransportStateTests {
    @Test
    func fallbackAlwaysCarriesItsReason() {
        let state = ShellTransportState.sshFallback(
            reason: .udpTimeout,
            diagnostics: nil
        )

        #expect(state.transport == .sshFallback)
        #expect(state.fallbackReason == .udpTimeout)
        #expect(state.fallbackDiagnostics == nil)
    }

    @Test
    func onlyActionableMoshFallbacksOfferServerMaintenance() {
        #expect(
            ShellTransportState.sshFallback(reason: .serverMissing, diagnostics: nil)
                .moshServerMaintenanceAction == .install
        )
        #expect(
            ShellTransportState.sshFallback(reason: .serverRuntimeBroken, diagnostics: nil)
                .moshServerMaintenanceAction == .repair
        )
        #expect(
            ShellTransportState.sshFallback(reason: .udpTimeout, diagnostics: nil)
                .moshServerMaintenanceAction == nil
        )
        #expect(ShellTransportState.ssh.moshServerMaintenanceAction == nil)
    }

    @Test
    func clearingDiagnosticsPreservesTheFallbackReason() {
        var state = ShellTransportState.sshFallback(
            reason: .bootstrapFailed,
            diagnostics: .make(
                reason: .bootstrapFailed,
                events: [],
                appContext: .init(version: "test", platform: "test")
            )
        )

        state.clearFallbackDiagnostics()

        #expect(state == .sshFallback(reason: .bootstrapFailed, diagnostics: nil))
    }

    @Test
    func directTransportsNeverExposeFallbackData() {
        let states: [ShellTransportState] = [.ssh, .mosh, .eternalTerminal]

        for state in states {
            #expect(state.fallbackReason == nil)
            #expect(state.fallbackDiagnostics == nil)
        }
    }
}
