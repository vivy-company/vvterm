import Foundation
import os.log
import MoshCore

extension SSHClient {
    // MARK: - Shell

    func startShell(
        cols: Int = 80,
        rows: Int = 24,
        pixelSize: TerminalPixelSize? = nil,
        startupCommand: String? = nil
    ) async throws -> ShellHandle {
        try Task.checkCancellation()
        guard !isAborted, let sshSession = session else {
            throw SSHError.notConnected
        }

        let connectionMode = connectedServer?.connectionMode ?? .standard
        let environment = await remoteEnvironment()
        try validateShellStartupSession(sshSession)
        let terminalType = await remoteTerminalType()
        try validateShellStartupSession(sshSession)
        if connectionMode != .mosh {
            let sshShell = try await startValidatedSSHShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            return ShellHandle(
                id: sshShell.id,
                stream: sshShell.stream,
                transportState: .ssh
            )
        }

        guard environment.platform != .windows && environment.shellProfile.family == .posix else {
            logger.warning("Mosh requested, but remote environment does not support Mosh runtime. Falling back to SSH.")
            let fallbackToken = startupTrace?.begin(.sshFallback)
            let fallbackShell = try await startValidatedSSHShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                pixelSize: pixelSize,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            if let fallbackToken { startupTrace?.end(fallbackToken, detail: "unsupported_remote") }
            return ShellHandle(
                id: fallbackShell.id,
                stream: fallbackShell.stream,
                transportState: .sshFallback(
                    reason: .unsupportedRemoteCapabilities,
                    diagnostics: MoshFallbackDiagnostics.make(
                        reason: .unsupportedRemoteCapabilities,
                        events: startupTrace?.snapshot() ?? []
                    )
                )
            )
        }

        do {
            let preparedMosh = try await prepareMoshShell(
                using: sshSession,
                cols: cols,
                rows: rows,
                startupCommand: startupCommand,
                terminalType: terminalType
            )
            do {
                try validateShellStartupSession(sshSession)
            } catch {
                await discardPreparedMoshShell(preparedMosh)
                throw error
            }
            pendingMoshServerLeases.removeValue(forKey: preparedMosh.leaseID)
            return registerMoshShell(preparedMosh.shell)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let sshError = error as? SSHError, case .notConnected = sshError {
                throw sshError
            }
            let moshError = error
            let fallbackReason = fallbackReason(for: moshError)
            logger.warning("Mosh startup failed, using SSH fallback: \(moshError.localizedDescription)")

            do {
                let fallbackToken = startupTrace?.begin(.sshFallback)
                let fallbackShell = try await startValidatedSSHShell(
                    using: sshSession,
                    cols: cols,
                    rows: rows,
                    pixelSize: pixelSize,
                    startupCommand: startupCommand,
                    environment: environment,
                    terminalType: terminalType
                )
                if let fallbackToken {
                    startupTrace?.end(fallbackToken, detail: fallbackReason.rawValue)
                }
                return ShellHandle(
                    id: fallbackShell.id,
                    stream: fallbackShell.stream,
                    transportState: .sshFallback(
                        reason: fallbackReason,
                        diagnostics: MoshFallbackDiagnostics.make(
                            reason: fallbackReason,
                            events: startupTrace?.snapshot() ?? []
                        )
                    )
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let sshError = error as? SSHError, case .notConnected = sshError {
                    throw sshError
                }
                throw SSHError.moshSessionFailed(
                    "Mosh startup failed (\(moshError.localizedDescription)); SSH fallback failed (\(error.localizedDescription))"
                )
            }
        }
    }

    private func startValidatedSSHShell(
        using expectedSession: SSHSession,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?,
        startupCommand: String?,
        environment: RemoteEnvironment,
        terminalType: RemoteTerminalType
    ) async throws -> ShellHandle {
        try validateShellStartupSession(expectedSession)
        let shell = try await expectedSession.startShell(
            cols: cols,
            rows: rows,
            pixelSize: pixelSize,
            startupCommand: startupCommand,
            environment: environment,
            terminalType: terminalType
        )
        do {
            try validateShellStartupSession(expectedSession)
            return shell
        } catch {
            await expectedSession.closeShell(shell.id)
            throw error
        }
    }

    func validateShellStartupSession(_ expectedSession: SSHSession) throws {
        try Task.checkCancellation()
        guard !isAborted,
              let currentSession = session,
              currentSession === expectedSession else {
            throw SSHError.notConnected
        }
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        guard !isAborted else {
            throw SSHError.notConnected
        }

        if let runtime = moshShells[shellId] {
            do {
                try await runtime.session.enqueue(.keystrokes(data))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.write(data, to: shellId)
    }

    func resize(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        for shellId: UUID
    ) async throws {
        if let runtime = moshShells[shellId] {
            guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
                throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
            }
            do {
                try await runtime.session.enqueue(.resize(cols: wireSize.cols, rows: wireSize.rows))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.resize(
            cols: cols,
            rows: rows,
            pixelSize: pixelSize,
            for: shellId
        )
    }

    func closeShell(_ shellId: UUID) async {
        if let runtime = moshShells.removeValue(forKey: shellId) {
            runtime.streamTask.cancel()
            await runtime.output.cancel()
            await runtime.session.stop()
            return
        }

        guard let session = session else { return }
        await session.closeShell(shellId)
    }
}
