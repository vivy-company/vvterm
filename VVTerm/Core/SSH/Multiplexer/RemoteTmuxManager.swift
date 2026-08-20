import Foundation
import os.log

actor RemoteTmuxManager {
    static let shared = RemoteTmuxManager()

    private let availabilityTimeout: Duration = .seconds(8)
    private let listTimeout: Duration = .seconds(12)
    private let configTimeout: Duration = .seconds(20)
    private let killTimeout: Duration = .seconds(10)
    private let cleanupTimeout: Duration = .seconds(20)
    private let pathTimeout: Duration = .seconds(10)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "Tmux"
    )

    private init() {}

    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability {
        let probeId = UUID().uuidString
        let startedAt = ContinuousClock.now
        logger.info("Starting tmux availability probe \(probeId, privacy: .public)")
        let environment = await client.remoteEnvironment()
        guard !Task.isCancelled else {
            return .indeterminate(.cancelled)
        }
        let result = await tmuxAvailability(in: environment) { command, timeout in
            try await client.execute(command, timeout: timeout)
        }
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        logger.info(
            "Tmux availability probe \(probeId, privacy: .public) resolved \(result.logDescription, privacy: .public) after \(String(describing: elapsed), privacy: .public)"
        )
        return result
    }

    func tmuxAvailability(
        in environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteTmuxAvailability {
        guard !Task.isCancelled else { return .indeterminate(.cancelled) }
        guard environment.supportsTmuxRuntime else { return .unsupported }

        if environment.platform == .windows {
            return await windowsPsmuxAvailability(for: environment, execute: execute)
        }

        let okMarker = "__VVTERM_TMUX_OK__"
        let command = RemoteTmuxCommandBuilder.tmuxAvailabilityProbeCommand(okMarker: okMarker)
        do {
            let output = try await execute(command, availabilityTimeout)
            try Task.checkCancellation()
            return RemoteTmuxParser.classifyAvailabilityOutput(
                output,
                availableMarker: okMarker,
                missingMarker: "__VVTERM_TMUX_NO__",
                backend: .unixTmux
            )
        } catch {
            return .indeterminate(.resolve(error))
        }
    }

    private func availableBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        await tmuxAvailability(using: client).backend
    }

    private func resolveBackend(
        _ explicitBackend: RemoteTmuxBackend?,
        using client: SSHClient
    ) async -> RemoteTmuxBackend? {
        if let explicitBackend {
            return explicitBackend
        }
        return await availableBackend(using: client)
    }

    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        let environment = await client.remoteEnvironment()
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            let powerShellExecutable = RemoteTmuxCommandBuilder.windowsPowerShellExecutable(
                for: environment
            )
            if environment.shellProfile.family == .cmd, powerShellExecutable == nil {
                return nil
            }
            return .windowsPsmux(
                commandName: "psmux",
                shellFamily: environment.shellProfile.family,
                powerShellExecutable: powerShellExecutable
            )
        }

        return .unixTmux
    }

    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession] {
        let candidates = RemoteTmuxCommandBuilder.listSessionCommands(backend: backend)
        var lastError: Error?
        var completedProbe = false

        for (index, command) in candidates.enumerated() {
            do {
                let output = try await client.execute(command, timeout: listTimeout)
                completedProbe = true
                let sessions = RemoteTmuxParser.parseSessionListOutput(
                    output,
                    allowLegacy: index == candidates.count - 1
                )

                if !sessions.isEmpty {
                    return sessions
                }
            } catch {
                lastError = error
            }
        }

        if completedProbe {
            return []
        }
        throw lastError ?? SSHError.unknown("Unable to list tmux sessions")
    }

    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend, case .windowsPsmux = backend else { return }
        let command = RemoteTmuxCommandBuilder.windowsConfigWriteCommand(
            terminalType: terminalType,
            themeStyle: themeStyle,
            backend: backend
        )
        _ = try? await client.execute(command, timeout: configTimeout)
    }

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async throws {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try await client.write(data, to: shellId)
    }

    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return }
        let command = RemoteTmuxCommandBuilder.killSessionCommand(
            named: sessionName,
            backend: backend
        )
        _ = try? await client.execute(command, timeout: killTimeout)
    }

    func cleanupLegacySessions(
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return }
        guard case .unixTmux = backend else { return }
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | awk '$1 ~ /^vvterm_[0-9a-fA-F-]+$/ && $2 == 0 { print $1 }' | while IFS= read -r name; do
            tmux kill-session -t "$name" 2>/dev/null || true;
          done;
        fi
        """
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        _ = try? await client.execute(command, timeout: cleanupTimeout)
    }

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return }
        let prefix = "vvterm_\(deviceId)_"
        let keep = sessionNames
        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await listSessions(using: client, backend: backend)
        } catch {
            logger.warning("Unable to list detached tmux sessions during cleanup [error: \(LogPrivacy.errorClass(error), privacy: .public)]")
            return
        }

        for session in sessions {
            guard session.name.hasPrefix(prefix) else { continue }
            guard session.attachedClients == 0 else { continue }
            guard !keep.contains(session.name) else { continue }
            await killSession(named: session.name, using: client, backend: backend)
        }
    }

    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async -> String? {
        let backend = await resolveBackend(explicitBackend, using: client)
        guard let backend else { return nil }
        let command = RemoteTmuxCommandBuilder.currentPathCommand(
            sessionName: sessionName,
            backend: backend
        )
        guard let output = try? await client.execute(command, timeout: pathTimeout) else { return nil }
        let trimmed = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func windowsPsmuxAvailability(
        for environment: RemoteEnvironment,
        execute: RemoteEnvironmentResolver.CommandExecutor
    ) async -> RemoteTmuxAvailability {
        let shellFamily = environment.shellProfile.family
        let powerShellExecutable = RemoteTmuxCommandBuilder.windowsPowerShellExecutable(
            for: environment
        )
        guard shellFamily == .powershell
                || (shellFamily == .cmd && powerShellExecutable != nil) else {
            return .unsupported
        }
        var firstIndeterminateFailure: RemoteTmuxProbeFailure?

        for (commandName, requirePsmuxExtension) in [
            ("psmux", false),
            ("pmux", false),
            ("tmux", true)
        ] {
            let backend = RemoteTmuxBackend.windowsPsmux(
                commandName: commandName,
                shellFamily: shellFamily,
                powerShellExecutable: powerShellExecutable
            )
            do {
                let output = try await execute(
                    RemoteTmuxCommandBuilder.windowsPsmuxAvailabilityProbeCommand(
                        commandName: commandName,
                        backend: backend,
                        requirePsmuxExtension: requirePsmuxExtension
                    ),
                    availabilityTimeout
                )
                try Task.checkCancellation()
                let resolution = RemoteTmuxParser.classifyAvailabilityOutput(
                    output,
                    availableMarker: "__VVTERM_TMUX_OK__:\(commandName)",
                    missingMarker: "__VVTERM_TMUX_NO__:\(commandName)",
                    backend: backend
                )
                switch resolution {
                case .available:
                    return resolution
                case .indeterminate(let failure):
                    firstIndeterminateFailure = firstIndeterminateFailure ?? failure
                case .confirmedMissing:
                    break
                case .unsupported:
                    assertionFailure("A supported Windows tmux probe resolved as unsupported")
                }
            } catch {
                firstIndeterminateFailure = firstIndeterminateFailure ?? .resolve(error)
            }
        }

        if let firstIndeterminateFailure {
            return .indeterminate(firstIndeterminateFailure)
        }
        return .confirmedMissing
    }

}
