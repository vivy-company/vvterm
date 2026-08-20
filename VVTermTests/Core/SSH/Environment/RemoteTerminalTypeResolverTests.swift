import Foundation
import Testing
@testable import VVTerm

private final class EmptyBundleToken {}

struct RemoteTerminalTypeResolverTests {
    private let posixEnvironment = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "zsh"),
        activeShellName: "zsh",
        powerShellExecutable: nil
    )

    private let cmdEnvironment = RemoteEnvironment(
        platform: .windows,
        shellProfile: .cmd,
        activeShellName: "cmd.exe",
        powerShellExecutable: nil
    )

    private let terminfoSource = """
    xterm-ghostty|ghostty|Ghostty,
    \tclear=\\E[H\\E[2J,
    \tE3=\\E[3J,
    """

    private enum TestError: Error {
        case commandFailed
        case invalidWrappedCommand
    }

    actor FakeExecutor {
        struct Invocation: Sendable {
            let command: String
            let timeout: Duration?
        }

        private var outputs: [Result<String, Error>]
        private var invocations: [Invocation] = []

        init(outputs: [Result<String, Error>]) {
            self.outputs = outputs
        }

        func run(command: String, timeout: Duration?) throws -> String {
            invocations.append(Invocation(command: command, timeout: timeout))
            guard !outputs.isEmpty else {
                Issue.record("Unexpected extra command: \(command)")
                return ""
            }
            switch outputs.removeFirst() {
            case .success(let output):
                return output
            case .failure(let error):
                throw error
            }
        }

        func recordedInvocations() -> [Invocation] {
            invocations
        }
    }

    @Test
    func resolveFallsBackForNonPOSIXRemotesWithoutExecutingCommands() async {
        let executor = FakeExecutor(outputs: [])

        let terminalType = await resolve(environment: cmdEnvironment, executor: executor)

        #expect(terminalType == .xterm256Color)
        #expect(await executor.recordedInvocations().isEmpty)
    }

    @Test
    func resolveUsesGhosttyForACompleteEntryInOneBoundedCommand() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_XTERM_GHOSTTY_INSTALLED__")
        ])

        let terminalType = await resolve(environment: posixEnvironment, executor: executor)

        let invocations = await executor.recordedInvocations()
        #expect(terminalType == .xtermGhostty)
        #expect(invocations.count == 1)
        #expect(invocations[0].timeout == .seconds(12))
        #expect(invocations[0].command.contains("infocmp -1 -x xterm-ghostty"))
        #expect(invocations[0].command.contains("tic -x"))
    }

    @Test
    func commandsRequireE3AndNeverTrustCompiledFileExistence() {
        let install = RemoteTerminalTypeResolver.installCommand(terminfoSource: terminfoSource)
        let probe = RemoteTerminalTypeResolver.probeCommand()

        for command in [install, probe] {
            #expect(command.contains("vvterm_xterm_ghostty_is_current"))
            #expect(command.contains("infocmp -1 -x xterm-ghostty"))
            #expect(command.contains("E3=\\E[3J,"))
            #expect(!command.contains("/x/xterm-ghostty"))
            #expect(!command.contains("/78/xterm-ghostty"))
        }
        #expect(install.contains("if ! command -v tic"))
        #expect(install.contains("if ! command -v infocmp"))
    }

    @Test
    func resolveInstallsTrustedSourceWhenEntryIsStale() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_XTERM_GHOSTTY_INSTALLED__")
        ])

        let terminalType = await resolve(environment: posixEnvironment, executor: executor)

        let command = await executor.recordedInvocations().first?.command
        #expect(terminalType == .xtermGhostty)
        #expect(command?.contains("tic -x -o \"$HOME/.terminfo\" -") == true)
        #expect(command?.contains("xterm-ghostty|ghostty|Ghostty") == true)
    }

    @Test(arguments: [
        "__VVTERM_XTERM_GHOSTTY_NO_TIC__",
        "__VVTERM_XTERM_GHOSTTY_INSTALL_FAILED__",
        "unexpected output"
    ])
    func resolveFallsBackForEveryUnusableInstallResult(_ output: String) async {
        let executor = FakeExecutor(outputs: [.success(output)])

        let terminalType = await resolve(environment: posixEnvironment, executor: executor)

        #expect(terminalType == .xterm256Color)
    }

    @Test
    func resolveFallsBackWhenInstallCommandThrows() async {
        let executor = FakeExecutor(outputs: [.failure(TestError.commandFailed)])

        let terminalType = await resolve(environment: posixEnvironment, executor: executor)

        #expect(terminalType == .xterm256Color)
    }

    @Test
    func missingBundledSourceUsesCapabilityProbeWithFiveSecondTimeout() async {
        let executor = FakeExecutor(outputs: [
            .success("__VVTERM_XTERM_GHOSTTY_OK__")
        ])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: posixEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            bundle: Bundle(for: EmptyBundleToken.self),
            terminfoSource: nil
        )

        let invocations = await executor.recordedInvocations()
        #expect(terminalType == .xtermGhostty)
        #expect(invocations.count == 1)
        #expect(invocations[0].timeout == .seconds(5))
    }

    @Test
    func bundledTerminfoSourceIncludesScrollbackEraseCapability() throws {
        let source = try #require(RemoteTerminalBootstrap.ghosttyTerminfoSource())

        #expect(source.contains("E3=\\E[3J,"))
    }

    #if os(macOS)
    @Test
    func completeEntryDoesNotInvokeTic() throws {
        let result = try runInstallCommand(
            infocmp: """
            printf '%s\\n' 'xterm-ghostty|ghostty,' ' E3=\\E[3J,'
            """,
            tic: """
            touch "$HOME/tic-called"
            cat >/dev/null
            """
        )

        #expect(result.output.contains("__VVTERM_XTERM_GHOSTTY_INSTALLED__"))
        #expect(!result.ticWasInvoked)
    }

    @Test
    func staleEntryIsRepairedAndPostValidated() throws {
        let result = try runInstallCommand(
            infocmp: """
            if [ -f "$HOME/current" ]; then
              printf '%s\\n' 'xterm-ghostty|ghostty,' ' E3=\\E[3J,'
            else
              printf '%s\\n' 'xterm-ghostty|ghostty,' ' clear=\\E[H\\E[2J,'
            fi
            """,
            tic: """
            cat >/dev/null
            touch "$HOME/current" "$HOME/tic-called"
            """
        )

        #expect(result.output.contains("__VVTERM_XTERM_GHOSTTY_INSTALLED__"))
        #expect(result.ticWasInvoked)
    }

    @Test
    func successfulCompileWithoutRequiredCapabilityFallsBack() throws {
        let result = try runInstallCommand(
            infocmp: """
            printf '%s\\n' 'xterm-ghostty|ghostty,' ' clear=\\E[H\\E[2J,'
            """,
            tic: """
            cat >/dev/null
            touch "$HOME/tic-called"
            """
        )

        #expect(result.output.contains("__VVTERM_XTERM_GHOSTTY_INSTALL_FAILED__"))
        #expect(result.ticWasInvoked)
    }

    @Test
    func missingTicReturnsBoundedFallbackMarker() throws {
        let result = try runInstallCommand(
            infocmp: "printf '%s\\n' 'xterm-ghostty|ghostty,' ' clear=\\E[H\\E[2J,'",
            tic: nil
        )

        #expect(result.output.contains("__VVTERM_XTERM_GHOSTTY_NO_TIC__"))
        #expect(!result.ticWasInvoked)
    }

    @Test
    func missingInfocmpAcceptsSuccessfulTrustedCompile() throws {
        let result = try runInstallCommand(
            infocmp: nil,
            tic: """
            cat >/dev/null
            touch "$HOME/tic-called"
            """
        )

        #expect(result.output.contains("__VVTERM_XTERM_GHOSTTY_INSTALLED__"))
        #expect(result.ticWasInvoked)
    }

    @Test
    func missingInfocmpAndTicReturnBoundedFallbackMarker() throws {
        let result = try runInstallCommand(infocmp: nil, tic: nil)

        #expect(result.output.contains("__VVTERM_XTERM_GHOSTTY_NO_TIC__"))
        #expect(!result.ticWasInvoked)
    }
    #endif

    private func resolve(
        environment: RemoteEnvironment,
        executor: FakeExecutor
    ) async -> RemoteTerminalType {
        await RemoteTerminalTypeResolver.resolve(
            environment: environment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: terminfoSource
        )
    }

    #if os(macOS)
    private struct InstallCommandResult {
        let output: String
        let ticWasInvoked: Bool
    }

    private func runInstallCommand(infocmp: String?, tic: String?) throws -> InstallCommandResult {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let command = RemoteTerminalTypeResolver.installCommand(terminfoSource: terminfoSource)
        let commandBody = try unwrappedLoginShellBody(command)
        let toolAvailability = """
        command() {
          case "$2" in
            infocmp) return \(infocmp == nil ? 1 : 0) ;;
            tic) return \(tic == nil ? 1 : 0) ;;
            *) return 0 ;;
          esac
        }
        """
        let infocmpFunction = infocmp.map {
            """
            infocmp() {
            \($0)
            }
            """
        } ?? ""
        let ticFunction = tic.map {
            """
            tic() {
            \($0)
            }
            """
        } ?? ""
        process.arguments = [
            "-c",
            """
            \(toolAvailability)
            \(infocmpFunction)
            \(ticFunction)
            \(commandBody)
            """
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return InstallCommandResult(
            output: String(decoding: data, as: UTF8.self),
            ticWasInvoked: fileManager.fileExists(atPath: home.appendingPathComponent("tic-called").path)
        )
    }

    private func unwrappedLoginShellBody(_ command: String) throws -> String {
        let prefix = "sh -lc "
        guard command.hasPrefix(prefix) else { throw TestError.invalidWrappedCommand }
        let quoted = command.dropFirst(prefix.count)
        guard quoted.first == "'", quoted.last == "'" else {
            throw TestError.invalidWrappedCommand
        }
        return String(quoted.dropFirst().dropLast())
            .replacingOccurrences(of: "'\\''", with: "'")
    }
    #endif
}
