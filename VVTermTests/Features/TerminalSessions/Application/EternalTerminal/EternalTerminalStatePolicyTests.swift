import ETBootstrap
import Foundation
import Testing
@testable import VVTerm

struct EternalTerminalStatePolicyTests {
    #if os(iOS)
    @Test
    func restoredETCheckpointIsPresentedAsReadyToResumeNotDisconnected() {
        #expect(
            ActiveConnectionPresentationStatus(
                connectionState: .disconnected,
                connectionMode: .eternalTerminal,
                hasResumeCheckpoint: true
            ) == .resumable
        )
        #expect(
            ActiveConnectionPresentationStatus(
                connectionState: .disconnected,
                connectionMode: .eternalTerminal,
                hasResumeCheckpoint: false
            ) == .disconnected
        )
        #expect(
            ActiveConnectionPresentationStatus(
                connectionState: .connected,
                connectionMode: .eternalTerminal,
                hasResumeCheckpoint: true
            ) == .connected
        )
        #expect(
            ActiveConnectionPresentationStatus(
                connectionState: .disconnected,
                connectionMode: .standard,
                hasResumeCheckpoint: true
            ) == .disconnected
        )
        #expect(
            ActiveConnectionPresentationStatus(
                connectionState: .disconnected,
                connectionMode: .mosh,
                hasResumeCheckpoint: true
            ) == .resumable
        )
    }

    #endif

    @Test
    func recoverableTransportStatesRemainInReconnectPresentation() {
        #expect(
            EternalTerminalStatePolicy.connectionState(
                for: .disconnected,
                host: "example.com",
                port: 2022
            ) == .reconnecting(attempt: 1)
        )
        #expect(
            EternalTerminalStatePolicy.connectionState(
                for: .reconnecting,
                host: "example.com",
                port: 2022
            ) == .reconnecting(attempt: 1)
        )
    }

    @Test
    func permanentRecoveryFailureRequiresANewSession() {
        let state = EternalTerminalStatePolicy.connectionState(
            for: .failed(.sessionUnrecoverable),
            host: "example.com",
            port: 2022
        )

        #expect(state == .failed(.eternalTerminal(
            failure: .sessionUnrecoverable,
            host: "example.com",
            port: 2022
        )))
        #expect(
            EternalTerminalFailureAnalytics.analyticsCategory(
                for: EternalTerminalSessionFailure.sessionUnrecoverable
            ) == "recovery"
        )
    }

    @Test
    func transportFailureIncludesTheConfiguredEndpoint() {
        let message = eternalTerminalFailureMessage(
            for: EternalTerminalSessionFailure.transport,
            host: "et.example.com",
            port: 22022
        )

        #expect(message.contains("et.example.com:22022"))
        #expect(message.contains("TCP port 22022"))
    }

    @Test
    func bootstrapCommandUsesKnownPOSIXShellAndExpandedPath() {
        let command = SSHETBootstrapExecutor.remoteBootstrapCommand("start-et")

        #expect(command.hasPrefix("/bin/sh -lc"))
        #expect(command.contains("export PATH="))
        #expect(command.contains("command -v etterminal"))
        #expect(command.contains("start-et"))
        #expect(!command.contains("(start-et) 2>&1"))
    }

    @Test
    func bootstrapRequestsETTerminalDiagnosticsOnStandardOutput() {
        #expect(
            SSHETBootstrapExecutor.bootstrapOptions.etterminalPath
                == "etterminal --logtostdout"
        )
    }

    @Test
    func missingBootstrapMarkerIncludesTheSanitizedHostResponse() {
        let message = eternalTerminalFailureMessage(
            for: EternalTerminalSessionFailure.bootstrapResponse(
                "sh: etterminal: command not found"
            ),
            host: "example.com",
            port: 2022
        )

        #expect(message.contains("Host response:"))
        #expect(message.contains("etterminal: command not found"))
    }

    @Test
    func unavailableETDaemonHasActionableServiceGuidance() {
        let message = eternalTerminalFailureMessage(
            for: EternalTerminalSessionFailure.bootstrapResponse(
                "Error: Connection error communicating with et daemon: No such file or directory."
            ),
            host: "example.com",
            port: 2022
        )

        #expect(message.contains("server daemon is not running or uses a different socket"))
        #expect(message.contains("sudo systemctl enable --now et"))
        #expect(message.contains("brew services start et"))
        #expect(message.contains("same server FIFO"))
        #expect(!message.contains("Stack Trace"))
    }

    @Test
    func wslEnvironmentUsesTheSupportedPOSIXPath() {
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "bash"),
            activeShellName: "bash",
            powerShellExecutable: nil
        )

        #expect(EternalTerminalHostCompatibility(environment: environment) == .supported)
    }

    @Test
    func nativeWindowsIsRejectedBeforePOSIXBootstrap() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let compatibility = EternalTerminalHostCompatibility(environment: environment)
        let message = eternalTerminalFailureMessage(
            for: EternalTerminalSessionFailure.bootstrapResponse(
                compatibility.bootstrapDiagnostic ?? ""
            ),
            host: "windows.example.com",
            port: 2022
        )

        #expect(compatibility == .unsupportedNativeWindows)
        #expect(message.contains("does not run as a native Windows"))
        #expect(message.contains("WSL"))
        #expect(message.contains("SSH with psmux"))
    }

    @Test
    func unknownNonPOSIXShellHasActionableGuidance() {
        let environment = RemoteEnvironment(
            platform: .unknown,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: nil
        )
        let compatibility = EternalTerminalHostCompatibility(environment: environment)
        let message = eternalTerminalFailureMessage(
            for: EternalTerminalSessionFailure.bootstrapResponse(
                compatibility.bootstrapDiagnostic ?? ""
            ),
            host: "example.com",
            port: 2022
        )

        #expect(compatibility == .unsupportedShell)
        #expect(message.contains("requires a POSIX login shell"))
    }

    @Test
    func tmuxStartupUsesAShortSelfDeletingRemoteScript() throws {
        let token = try #require(UUID(uuidString: "45B943D4-58C7-4BC9-B089-A9F0ED25C2D3"))
        let command = String(repeating: "tmux set-option -g mouse on; ", count: 100)
        let remotePath = EternalTerminalStartupCommand.remoteScriptPath(token: token)
        let script = EternalTerminalStartupCommand.script(
            command: command,
            remotePath: remotePath
        )
        let invocation = EternalTerminalStartupCommand.invocation(remotePath: remotePath)

        #expect(remotePath == "/tmp/vvterm-et-start-45b943d4-58c7-4bc9-b089-a9f0ed25c2d3.sh")
        #expect(script.hasPrefix("rm -f -- '\(remotePath)'\n"))
        #expect(script.hasSuffix(command))
        #expect(invocation == "/bin/sh '\(remotePath)'")
        #expect(!invocation.contains(command))
        #expect(invocation.count < 100)
    }
}

private nonisolated func eternalTerminalFailureMessage(
    for failure: EternalTerminalSessionFailure,
    host: String,
    port: Int
) -> String {
    TerminalConnectionFailurePresentation.message(
        for: .eternalTerminal(
            failure: failure,
            host: host,
            port: port
        )
    )
}
