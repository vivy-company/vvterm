import Foundation
import Testing
@testable import VVTerm

private actor TmuxProbeExecutor {
    private var outputs: [Result<String, Error>]
    private var commands: [String] = []

    init(outputs: [Result<String, Error>]) {
        self.outputs = outputs
    }

    func run(command: String, timeout _: Duration?) throws -> String {
        commands.append(command)
        guard !outputs.isEmpty else {
            Issue.record("Unexpected extra command: \(command)")
            return ""
        }
        return try outputs.removeFirst().get()
    }

    func recordedCommands() -> [String] {
        commands
    }
}

enum InjectedTmuxProbeError: CaseIterable, Sendable {
    case timeout
    case disconnected
    case cancelled
    case transport
    case channelOpenFailed
    case shellRequestFailed

    var error: Error {
        switch self {
        case .timeout: return SSHError.timeout
        case .disconnected: return SSHError.notConnected
        case .cancelled: return CancellationError()
        case .transport: return SSHError.socketError("connection reset")
        case .channelOpenFailed: return SSHError.channelOpenFailed
        case .shellRequestFailed: return SSHError.shellRequestFailed
        }
    }

    var expectedFailure: RemoteTmuxProbeFailure {
        switch self {
        case .timeout: return .timeout
        case .disconnected: return .disconnected
        case .cancelled: return .cancelled
        case .transport: return .transport("connection reset")
        case .channelOpenFailed: return .channelOpenFailed
        case .shellRequestFailed: return .shellRequestFailed
        }
    }
}

struct RemoteTmuxAvailabilityTests {
    private func resolveAvailability(
        environment: RemoteEnvironment = .fallbackPOSIX,
        outputs: [Result<String, Error>]
    ) async -> (RemoteTmuxAvailability, [String]) {
        let executor = TmuxProbeExecutor(outputs: outputs)
        let availability = await RemoteTmuxManager.shared.tmuxAvailability(
            in: environment
        ) { command, timeout in
            try await executor.run(command: command, timeout: timeout)
        }
        return (availability, await executor.recordedCommands())
    }

    @Test
    func explicitAvailabilityMarkerReportsUnixTmuxAvailable() async {
        let (availability, commands) = await resolveAvailability(outputs: [
            .success("__VVTERM_TMUX_OK__")
        ])

        #expect(availability == .available(.unixTmux))
        #expect(commands.count == 1)
    }

    @Test
    func explicitMissingMarkerConfirmsUnixTmuxMissing() async {
        let (availability, _) = await resolveAvailability(outputs: [
            .success("__VVTERM_TMUX_NO__")
        ])

        #expect(availability == .confirmedMissing)
    }

    @Test(arguments: InjectedTmuxProbeError.allCases)
    func probeErrorsRemainIndeterminate(error: InjectedTmuxProbeError) async {
        let (availability, _) = await resolveAvailability(outputs: [
            .failure(error.error)
        ])

        #expect(availability == .indeterminate(error.expectedFailure))
    }

    @Test(arguments: ["", "unexpected output", "__VVTERM_TMUX_OK____VVTERM_TMUX_NO__"])
    func emptyMalformedAndConflictingProbeOutputRemainIndeterminate(output: String) async {
        let (availability, _) = await resolveAvailability(outputs: [.success(output)])

        #expect(availability == .indeterminate(.invalidResponse))
    }

    @Test
    func unsupportedEnvironmentDoesNotRunTmuxProbe() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .unknown(),
            activeShellName: nil,
            powerShellExecutable: "powershell"
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: []
        )

        #expect(availability == .unsupported)
        #expect(commands.isEmpty)
    }

    @Test
    func cmdWithoutDetectedPowerShellDoesNotRunTmuxProbe() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: nil
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: []
        )

        #expect(availability == .unsupported)
        #expect(commands.isEmpty)
    }

    @Test
    func windowsConfirmsMissingOnlyAfterEveryCandidateReportsMissing() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: [
                .success("__VVTERM_TMUX_NO__:psmux"),
                .success("__VVTERM_TMUX_NO__:pmux"),
                .success("__VVTERM_TMUX_NO__:tmux")
            ]
        )

        #expect(availability == .confirmedMissing)
        #expect(commands.count == 3)
    }

    @Test
    func oneIndeterminateWindowsCandidatePreventsFalseMissingResult() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let (availability, _) = await resolveAvailability(
            environment: environment,
            outputs: [
                .failure(SSHError.timeout),
                .success("__VVTERM_TMUX_NO__:pmux"),
                .success("__VVTERM_TMUX_NO__:tmux")
            ]
        )

        #expect(availability == .indeterminate(.timeout))
    }

    @Test
    func laterAvailableWindowsCandidateWinsAfterEarlierIndeterminateProbe() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let (availability, commands) = await resolveAvailability(
            environment: environment,
            outputs: [
                .failure(SSHError.timeout),
                .success("__VVTERM_TMUX_OK__:pmux")
            ]
        )

        #expect(
            availability == .available(.windowsPsmux(
                commandName: "pmux",
                shellFamily: .powershell,
                powerShellExecutable: "pwsh"
            ))
        )
        #expect(commands.count == 2)
    }
    @Test
    func availabilityProbeUsesFallbackPathsAndNonLoginShell() {
        let probe = RemoteTmuxCommandBuilder.tmuxAvailabilityProbeCommand(
            okMarker: "__VVTERM_TMUX_OK__"
        )
        #expect(probe.hasPrefix("sh -c "))
        #expect(!probe.contains("sh -lc "))
        #expect(probe.contains("command -v tmux"))
        #expect(probe.contains("/usr/bin/tmux"))
        #expect(probe.contains("/bin/tmux"))
        #expect(probe.contains("/usr/local/bin/tmux"))
        #expect(probe.contains("-V >/dev/null 2>&1"))
        #expect(probe.contains("__VVTERM_TMUX_OK__"))
        #expect(probe.contains("__VVTERM_TMUX_NO__"))
    }
}

