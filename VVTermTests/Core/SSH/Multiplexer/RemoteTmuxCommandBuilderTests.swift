import Testing
@testable import VVTerm

nonisolated let deterministicRemoteTmuxThemeStyle = RemoteTmuxThemeStyle(
    name: "Aizen Dark",
    modeStyle: "fg=#d0d6f0,bg=#333333"
)

struct RemoteTmuxCommandBuilderTests {
    @Test
    func identicalUnixAttachInputsProduceIdenticalCommands() {
        let first = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm-device-session",
            workingDirectory: "/srv/app",
            lifecycleMarkerToken: "marker",
            transport: .ssh
        )
        let second = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm-device-session",
            workingDirectory: "/srv/app",
            lifecycleMarkerToken: "marker",
            transport: .ssh
        )

        #expect(first == second)
        #expect(first.contains("fg=#d0d6f0,bg=#333333"))
    }

    @Test
    func identicalWindowsInstallInputsProduceIdenticalCommands() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let first = RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "prod",
            workingDirectory: #"C:\work\app"#,
            terminalType: .xtermGhostty,
            backend: backend
        )
        let second = RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "prod",
            workingDirectory: #"C:\work\app"#,
            terminalType: .xtermGhostty,
            backend: backend
        )

        #expect(first == second)
        #expect(first.contains("from theme: Aizen Dark"))
        #expect(first.contains("set -g mode-style \"fg=#d0d6f0,bg=#333333\""))
    }

    @Test
    func parserOutputDependsOnlyOnSuppliedTextAndLegacyMode() {
        let output = "prod 2 3\ndev 0 1\n"

        let first = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)
        let second = RemoteTmuxParser.parseSessionListOutput(output, allowLegacy: false)

        #expect(first == second)
        #expect(first.map(\.name) == ["prod", "dev"])
    }
}
