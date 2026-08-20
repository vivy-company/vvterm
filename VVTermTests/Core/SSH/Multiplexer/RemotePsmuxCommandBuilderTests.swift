import Foundation
import Testing
@testable import VVTerm

struct RemotePsmuxCommandBuilderTests {
    @Test
    func externalWindowsSessionAttachDoesNotLoadVVTermConfiguration() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "external team; session",
            ownership: .external,
            backend: backend
        )

        #expect(command.contains("attach-session -d -t $vvtermSession"))
        #expect(!command.contains("source-file"))
        #expect(!command.contains("$vvtermConfig"))
    }

    @Test
    func managedWindowsSessionAttachLoadsVVTermConfiguration() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_managed",
            ownership: .managed,
            backend: backend
        )

        #expect(command.contains("source-file -t $vvtermSession $vvtermConfig"))
        #expect(command.contains("-u attach-session"))
    }

    @Test
    func windowsPsmuxAttachCommandUsesPowerShellAndPsmux() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_demo",
            workingDirectory: "C:/Users/me/project",
            backend: backend
        )

        #expect(command.contains("$vvtermPsmux = 'psmux'"))
        #expect(command.contains("has-session -t $vvtermSession"))
        #expect(command.contains("attach-session -d -t $vvtermSession"))
        #expect(command.contains("new-session -A -s $vvtermSession -c $vvtermWorkingDirectory"))
        #expect(command.contains("[Convert]::FromBase64String('QzpcVXNlcnNcbWVccHJvamVjdA==')"))
        #expect(command.contains("$HOME + '\\.vvterm\\psmux.conf'"))
        #expect(!command.contains("$vvtermExactSession"))
        #expect(!command.contains("sh -lc"))
        #expect(!command.contains("export PATH"))
        #expect(!command.contains("mkdir -p"))
        #expect(!command.contains("printf"))
        #expect(!command.contains("uname"))
        #expect(!command.contains("exec tmux"))
    }

    @Test(arguments: [
        "C:/work/$(Get-Process)",
        "C:/work/`Get-Process`",
        "C:/work/$env:USERPROFILE",
        "C:/work/O'Hara",
        "C:/work/line\nbreak",
        "C:/work/ユニコード",
        "-leading-option"
    ])
    func windowsWorkingDirectoryIsOneOpaquePowerShellArgument(_ workingDirectory: String) {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )
        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_secure",
            workingDirectory: workingDirectory,
            backend: backend
        )
        let normalized = workingDirectory.replacingOccurrences(of: "/", with: "\\")
        let encoded = Data(normalized.utf8).base64EncodedString()
        let expression = "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)'))"

        #expect(command.contains("$vvtermWorkingDirectory = \(expression)"))
        #expect(command.contains("-c $vvtermWorkingDirectory"))
    }

    @Test
    func unsupportedWindowsShellProfileDoesNotGeneratePsmuxCommand() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .unknown,
            powerShellExecutable: nil
        )

        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_secure",
            workingDirectory: "C:/work",
            backend: backend
        )

        #expect(command.isEmpty)
    }

    @Test
    func windowsPsmuxLifecycleCommandReportsDetachOrSessionEnd() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_demo",
            workingDirectory: "C:/work",
            backend: backend,
            lifecycleMarkerToken: "marker-token"
        )

        #expect(command.contains("has-session -t $vvtermSession"))
        #expect(command.contains("[Console]::Out.Write"))
        #expect(command.contains("marker-token"))
        #expect(command.contains("detached"))
        #expect(command.contains("ended"))
        #expect(command.contains("creationFailed"))
        #expect(command.contains("$vvtermTmuxCreateStatus = $LASTEXITCODE"))
    }

    @Test
    func windowsCmdPsmuxAttachCommandWrapsPowerShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "pmux",
            shellFamily: .cmd,
            powerShellExecutable: "powershell"
        )

        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "shared",
            ownership: .external,
            backend: backend
        )

        #expect(command.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
    }

    @Test
    func windowsPowerShellAttachExistingFallsBackToInteractiveShell() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "shared",
            ownership: .external,
            backend: backend
        )

        #expect(command.contains("} else {"))
        #expect(command.contains("& 'pwsh'"))
    }

    @Test
    func windowsPsmuxAvailabilityProbeConfirmsTmuxAliasWithPsmuxExtension() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "tmux",
            shellFamily: .powershell,
            powerShellExecutable: "powershell"
        )

        let probe = RemoteTmuxCommandBuilder.windowsPsmuxAvailabilityProbeCommand(
            commandName: "tmux",
            backend: backend,
            requirePsmuxExtension: true
        )

        #expect(probe.contains("Get-Command 'tmux'"))
        #expect(probe.contains("list-commands"))
        #expect(probe.contains("dump-state"))
        #expect(probe.contains("claim-session"))
        #expect(probe.contains("__VVTERM_TMUX_OK__:tmux"))
        #expect(probe.contains("__VVTERM_TMUX_NO__:tmux"))
    }

    @Test
    func windowsPsmuxInstallScriptUsesWindowsPackageManagersAndConfig() {
        let backend = RemoteTmuxBackend.windowsPsmux(
            commandName: "psmux",
            shellFamily: .powershell,
            powerShellExecutable: "pwsh"
        )

        let script = RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_demo",
            workingDirectory: "C:/work",
            terminalType: .xtermGhostty,
            backend: backend
        )

        #expect(script.contains("Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath"))
        #expect(script.contains("$HOME + '\\.vvterm\\psmux.conf'"))
        #expect(script.contains("winget install --id marlocarlo.psmux"))
        #expect(script.contains("scoop bucket add psmux https://github.com/psmux/scoop-psmux"))
        #expect(script.contains("choco install psmux -y"))
        #expect(script.contains("cargo install psmux"))
        #expect(script.contains("function Get-VVTermPsmuxCommand"))
        #expect(script.contains("Get-Command pmux -ErrorAction SilentlyContinue"))
        #expect(script.contains("$vvtermPsmux = $vvtermPsmuxCommand.Source"))
        #expect(script.contains("set -g allow-set-title on"))
        #expect(!script.contains("%if"))
        #expect(script.contains("set -g terminal-features[0] \"*:hyperlinks\""))
        #expect(!script.contains("irm "))
        #expect(!script.contains("WheelUpPane"))
        #expect(!script.contains("WheelDownPane"))
        #expect(!script.contains("scroll-on-clear"))
        #expect(!script.contains("sh -lc"))
    }
}

