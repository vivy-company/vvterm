import Testing
@testable import VVTerm

struct TerminalZenModePolicyTests {
    @Test
    func requiresSelectedTerminalAndActiveTab() {
        #expect(
            TerminalZenModePolicy.canEnter(
                isTerminalSelected: true,
                hasActiveTerminal: true
            )
        )
        #expect(
            !TerminalZenModePolicy.canEnter(
                isTerminalSelected: false,
                hasActiveTerminal: true
            )
        )
        #expect(
            !TerminalZenModePolicy.canEnter(
                isTerminalSelected: true,
                hasActiveTerminal: false
            )
        )
    }

    @Test
    func preservesZenModeAcrossViewsUntilRouteContextEnds() {
        #expect(
            TerminalZenModePolicy.resolvedEnabled(
                requested: true,
                hasRouteContext: true
            )
        )
        #expect(
            !TerminalZenModePolicy.resolvedEnabled(
                requested: true,
                hasRouteContext: false
            )
        )
        #expect(
            !TerminalZenModePolicy.resolvedEnabled(
                requested: false,
                hasRouteContext: true
            )
        )
    }
}
