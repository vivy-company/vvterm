import Testing
@testable import VVTerm

struct RemoteTmuxManagerParserTests {
    @Test
    func parseWhitespaceFormatFromRealTmuxOutput() {
        let output = """
        aizen-00F43729-7E11-4731-ADFE-603A766AFCF6 1 1
        aizen-7922A0D1-DD37-4530-866F-30C60B0E9C26 0 1
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0].name == "aizen-00F43729-7E11-4731-ADFE-603A766AFCF6")
        #expect(sessions[0].attachedClients == 1)
        #expect(sessions[0].windowCount == 1)
        #expect(!sessions[0].name.hasSuffix(" 1 1"))
        #expect(sessions[1].name == "aizen-7922A0D1-DD37-4530-866F-30C60B0E9C26")
        #expect(sessions[1].attachedClients == 0)
    }

    @Test
    func parseLiteralEscapedTabsFormat() {
        let output = "prod\\t2\\t3\ndev\\t0\\t1\n"

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "prod", attachedClients: 2, windowCount: 3))
        #expect(sessions[1] == RemoteTmuxSession(name: "dev", attachedClients: 0, windowCount: 1))
    }

    @Test
    func parseTwoFieldFormatDefaultsWindowCountToOne() {
        let output = """
        qa 1
        local 0
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "qa", attachedClients: 1, windowCount: 1))
        #expect(sessions[1] == RemoteTmuxSession(name: "local", attachedClients: 0, windowCount: 1))
    }

    @Test
    func parseLegacyListSessionsFormatWhenEnabled() {
        let output = """
        ops: 2 windows (created Sat Feb 14 10:00:00 2026) [80x24] (attached)
        api: 1 windows (created Sat Feb 14 10:01:00 2026) [80x24]
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: true)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(name: "ops", attachedClients: 1, windowCount: 2))
        #expect(sessions[1] == RemoteTmuxSession(name: "api", attachedClients: 0, windowCount: 1))
    }

    @Test
    func sortPrefersAttachedThenWindowCountThenName() {
        let output = """
        zeta 1 1
        alpha 1 3
        beta 1 3
        gamma 0 9
        """

        let sessions = RemoteTmuxManager.shared.parseSessionListOutput(output, allowLegacy: false)
        #expect(sessions.map(\.name) == ["alpha", "beta", "zeta", "gamma"])
    }
}
