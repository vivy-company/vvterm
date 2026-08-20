import Foundation
import Testing
@testable import VVTerm

struct RemoteTerminalBootstrapTests {
    private let posixEnvironment = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "zsh"),
        activeShellName: "zsh",
        powerShellExecutable: nil
    )

    private let powerShellEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .powershell(executableName: "powershell"),
        activeShellName: "powershell",
        powerShellExecutable: "powershell"
    )

    private let pwshEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .powershell(executableName: "pwsh"),
        activeShellName: "pwsh",
        powerShellExecutable: "pwsh"
    )

    private let cmdEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .cmd,
        activeShellName: "cmd.exe",
        powerShellExecutable: "powershell"
    )

    @Test
    func launchPlanWithoutStartupCommandUsesPOSIXLoginShellBootstrap() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: nil, environment: posixEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected POSIX login shell bootstrap when no startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("/bin/sh -lc \""))
            #expect(command.contains("exec \\\"\\$SHELL\\\" -l"))
            #expect(command.contains("TERM_PROGRAM"))
        }
    }

    @Test
    func launchPlanWithoutStartupCommandUsesInteractiveShellForCmd() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: nil, environment: cmdEnvironment)

        switch plan {
        case .shell:
            #expect(Bool(true))
        case .exec:
            Issue.record("Expected plain shell launch for cmd.exe when no startup command is provided")
        }
    }

    @Test
    func launchPlanWithStartupCommandUsesPOSIXExecWrapper() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: "echo hi", environment: posixEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected exec launch when a startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("/bin/sh -lc \""))
            #expect(command.contains("echo hi"))
            #expect(command.contains("TERM_PROGRAM"))
        }
    }

    @Test
    func posixWrapperRoundTripsShellMetacharactersForMosh() {
        let script = #"printf '%s\n' "$HOME" "$(printf 'nested')" '`' '\path'"#
        let wrapped = RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
        let moshScript = RemoteTerminalBootstrap.moshStartupScript(startCommand: wrapped)

        #expect(wrapped.hasPrefix("/bin/sh -lc \""))
        #expect(moshScript.contains(script))
    }

    @Test
    func launchPlanWithStartupCommandUsesEncodedPowerShellWrapper() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: "Write-Output 'hi'", environment: powerShellEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected exec launch when a PowerShell startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("powershell -NoLogo -NoProfile -EncodedCommand "))
        }
    }

    @Test
    func launchPlanWithStartupCommandKeepsPwshExecutable() {
        let plan = RemoteTerminalBootstrap.launchPlan(startupCommand: "Write-Output 'hi'", environment: pwshEnvironment)

        switch plan {
        case .shell:
            Issue.record("Expected exec launch when a pwsh startup command is provided")
        case .exec(let command):
            #expect(command.hasPrefix("pwsh -NoLogo -NoProfile -EncodedCommand "))
        }
    }

    @Test
    func directoryChangeCommandUsesPOSIXCdForUnixPaths() {
        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: "/var/www/app's",
            environment: posixEnvironment
        )

        #expect(plan == .command("cd -- '/var/www/app'\\''s'\n"))
    }

    @Test
    func directoryChangeCommandUsesPowerShellForWindowsPaths() {
        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: #"C:\Users\O'Hara\repo"#,
            environment: powerShellEnvironment
        )

        #expect(plan == .command("Set-Location -LiteralPath 'C:\\Users\\O''Hara\\repo'\r\n"))
    }

    @Test
    func directoryChangeCommandNormalizesOSCStyleWindowsPaths() {
        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: "/C:/Users/test/project",
            environment: powerShellEnvironment
        )

        #expect(plan == .command("Set-Location -LiteralPath 'C:\\Users\\test\\project'\r\n"))
    }

    @Test
    func directoryChangeCommandUsesCmdSyntaxForCmdProfile() {
        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: #"C:\Users\test\project"#,
            environment: cmdEnvironment
        )

        #expect(plan == .command("cd /d \"C:\\Users\\test\\project\"\r\n"))
    }

    @Test
    func cmdWorkingDirectorySupportsSpacesParenthesesUnicodeAndCaret() {
        let paths = [
            #"C:\Program Files (x86)"#,
            #"C:\Users\Wiedy Mi\项目"#,
            #"C:\safe^name"#,
            #"C:\safe&name"#
        ]

        for path in paths {
            #expect(
                RemoteTerminalBootstrap.workingDirectoryRestorePlan(
                    for: path,
                    environment: cmdEnvironment
                ) == .command("cd /d \"\(path)\"\r\n")
            )
        }
    }

    @Test
    func cmdWorkingDirectoryUsesPushdForUNCPath() {
        let path = #"\\server\share\Program Files (x86)"#

        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: path,
            environment: cmdEnvironment
        )

        #expect(plan == .command("pushd \"\(path)\"\r\n"))
    }

    @Test(arguments: [#"C:\literal\%USERPROFILE%"#, #"C:\literal\!name!"#])
    func cmdWorkingDirectoryPreservesExpansionCharactersAsLiteral(path: String) throws {
        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: path,
            environment: cmdEnvironment
        )
        let command = try #require(plan.command)
        let script = try #require(decodedPowerShellScript(from: command))

        #expect(!command.contains(path))
        #expect(script.contains("$env:VVTERM_CWD = \(RemoteTerminalBootstrap.powerShellQuoted(path))"))
        #expect(script.contains("$env:ComSpec /d /v:off /k"))
        #expect(script.contains(#"cd /d "%VVTERM_CWD%""#))
    }

    @Test(arguments: ["|", "<", ">", "\"", "\r", "\n", "\0"])
    func cmdWorkingDirectoryRejectsInjectionCharacters(character: String) {
        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: "C:\\safe\(character)whoami",
            environment: cmdEnvironment
        )

        #expect(plan == .keepDefault(.invalidWindowsPath))
    }

    @Test
    func cmdWorkingDirectoryReturnsTypedFailureWhenLiteralTransportIsUnavailable() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: nil
        )

        let plan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: #"C:\literal\%USERPROFILE%"#,
            environment: environment
        )

        #expect(plan == .keepDefault(.literalCmdPathRequiresPowerShell))
    }

    @Test
    func posixPastedPathQuotesShellSensitiveRemotePaths() {
        let pastedPath = RemoteTerminalBootstrap.posixPastedPath("/tmp/vv term/file's name.png")

        #expect(pastedPath == "'/tmp/vv term/file'\\''s name.png'")
    }

    @Test
    func terminalEnvironmentDictionaryIncludesResolvedTypeAndTrueColorCapabilities() {
        let environment = RemoteTerminalBootstrap.terminalEnvironmentDictionary(
            terminalType: .xtermGhostty
        )

        #expect(environment["TERM"] == "xterm-ghostty")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "ghostty")
        #expect(environment["TERM_PROGRAM_VERSION"] == RemoteTerminalBootstrap.appVersion())
        #expect(environment.count == 4)
    }

    @Test
    func terminalEnvironmentDictionaryKeepsCompatibilityTerminalFallback() {
        let environment = RemoteTerminalBootstrap.terminalEnvironmentDictionary(
            terminalType: .xterm256Color
        )

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
    }

    @Test
    func kittyGraphicsPolicyUsesOnlyTheETSpecificSnacksHint() {
        let ssh = RemoteTerminalBootstrap.terminalEnvironmentDictionary(
            terminalType: .xtermGhostty,
            transport: .ssh
        )
        let fallback = RemoteTerminalBootstrap.terminalEnvironmentDictionary(
            terminalType: .xtermGhostty,
            transport: .sshFallback
        )
        let eternalTerminal = RemoteTerminalBootstrap.terminalEnvironmentDictionary(
            terminalType: .xtermGhostty,
            transport: .eternalTerminal
        )
        let mosh = RemoteTerminalBootstrap.terminalEnvironmentDictionary(
            terminalType: .xtermGhostty,
            transport: .mosh
        )

        #expect(RemoteKittyGraphicsPolicy(transport: .ssh) == .genuineSSH)
        #expect(RemoteKittyGraphicsPolicy(transport: .sshFallback) == .genuineSSH)
        #expect(RemoteKittyGraphicsPolicy(transport: .eternalTerminal) == .eternalTerminal)
        #expect(RemoteKittyGraphicsPolicy(transport: .mosh) == .unsupported)
        #expect(ssh["SNACKS_SSH"] == nil)
        #expect(fallback["SNACKS_SSH"] == nil)
        #expect(mosh["SNACKS_SSH"] == nil)
        #expect(eternalTerminal["SNACKS_SSH"] == "1")
        for environment in [ssh, fallback, eternalTerminal] {
            #expect(environment["TERM_PROGRAM"] == "ghostty")
        }
        #expect(mosh["TERM_PROGRAM"] == nil)
        #expect(mosh["TERM_PROGRAM_VERSION"] == nil)
        for environment in [ssh, fallback, eternalTerminal, mosh] {
            #expect(environment["SSH_CONNECTION"] == nil)
            #expect(environment["SSH_CLIENT"] == nil)
            #expect(environment["SSH_TTY"] == nil)
        }
    }

    private func decodedPowerShellScript(from command: String) -> String? {
        guard let encodedCommand = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .last,
              let data = Data(base64Encoded: String(encodedCommand)) else {
            return nil
        }
        return String(data: data, encoding: .utf16LittleEndian)
    }
}
