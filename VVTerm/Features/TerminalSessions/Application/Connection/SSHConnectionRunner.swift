import Foundation
import os.log

nonisolated struct SSHConnectionInitialTerminalState: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pixelSize: TerminalPixelSize?
}

nonisolated struct SSHConnectionRunnerTransport: Sendable {
    let connect: @Sendable (_ server: Server, _ credentials: ServerCredentials) async throws -> Void
    let startShell: @Sendable (
        _ columns: Int,
        _ rows: Int,
        _ pixelSize: TerminalPixelSize?,
        _ startupCommand: String?
    ) async throws -> ShellHandle
    let disconnect: @Sendable () async -> Void
    let closeShell: @Sendable (_ shellId: UUID) async -> Void
    let execute: @Sendable (_ command: String, _ timeout: Duration?) async throws -> String

    static func live(client: SSHClient) -> Self {
        Self(
            connect: { server, credentials in
                _ = try await client.connect(to: server, credentials: credentials)
            },
            startShell: { columns, rows, pixelSize, startupCommand in
                try await client.startShell(
                    cols: columns,
                    rows: rows,
                    pixelSize: pixelSize,
                    startupCommand: startupCommand
                )
            },
            disconnect: {
                await client.disconnect()
            },
            closeShell: { shellId in
                await client.closeShell(shellId)
            },
            execute: { command, timeout in
                try await client.execute(command, timeout: timeout)
            }
        )
    }
}

nonisolated enum SSHConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        transport: SSHConnectionRunnerTransport,
        initialTerminalState: SSHConnectionInitialTerminalState,
        logger: Logger,
        shouldContinueConnection: @MainActor @escaping @Sendable () -> Bool,
        onAttempt: @MainActor @escaping @Sendable (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping @Sendable () async throws -> TerminalShellStartupPlan,
        restoreMoshShell: @MainActor @escaping @Sendable (_ cols: Int, _ rows: Int) async -> ShellHandle?,
        registerShell: @MainActor @escaping @Sendable (_ shell: ShellHandle) async -> Bool,
        onTitleChange: @MainActor @escaping @Sendable (_ title: String) -> Void,
        writeOutput: @MainActor @escaping @Sendable (_ data: Data) -> Bool,
        shouldResetClient: @escaping @Sendable (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping @Sendable (
            _ shellId: UUID,
            _ reason: TerminalShellEndReason
        ) -> Void,
        onFailure: @MainActor @escaping @Sendable (_ error: Error) -> Void
    ) async {
        guard credentials.isAuthorized(for: server) else {
            await onFailure(KeychainError.credentialServerMismatch)
            return
        }

        let maxAttempts = 3
        var lastError: Error?
        var titleParser = TerminalTitleSequenceParser()

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            guard await shouldContinueConnection() else { return }
            await onAttempt(attempt)

            do {
                logger.info(
                    "Connecting to \(server.host, privacy: .private(mask: .hash))... (attempt \(attempt))"
                )
                let cols = initialTerminalState.columns
                let rows = initialTerminalState.rows
                let pixelSize = initialTerminalState.pixelSize

                let shell: ShellHandle
                let startup: TerminalShellStartupPlan?
                if let restored = await restoreMoshShell(cols, rows) {
                    shell = restored
                    startup = nil
                    logger.info("Restored existing Mosh protocol session")
                } else {
                    try await transport.connect(server, credentials)
                    guard !Task.isCancelled else { return }
                    guard await shouldContinueConnection() else { return }

                    let freshStartup = try await startupPlan()
                    guard !Task.isCancelled else { return }
                    guard await shouldContinueConnection() else { return }
                    shell = try await transport.startShell(
                        cols,
                        rows,
                        pixelSize,
                        freshStartup.command
                    )
                    startup = freshStartup
                }

                guard !Task.isCancelled else {
                    await transport.closeShell(shell.id)
                    return
                }
                guard await shouldContinueConnection() else {
                    await transport.closeShell(shell.id)
                    return
                }
                guard await registerShell(shell) else { return }

                guard !Task.isCancelled else { return }
                var lifecycleParser = startup?.tmuxLifecycle.map {
                    TmuxLifecycleStreamParser(markerToken: $0.markerToken)
                }
                var lastLifecycleEvent: TmuxLifecycleEvent?
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    guard await shouldContinueConnection() else { break }
                    let visibleData: Data
                    if var parser = lifecycleParser {
                        let parsed = parser.consume(data)
                        lifecycleParser = parser
                        visibleData = parsed.output
                        if let event = parsed.events.last {
                            lastLifecycleEvent = event
                        }
                    } else {
                        visibleData = data
                    }

                    for title in titleParser.parse(visibleData) {
                        await onTitleChange(title)
                    }
                    let shouldContinue = await writeOutput(visibleData)
                    if !shouldContinue { break }
                }
                guard !Task.isCancelled else { return }
                guard await shouldContinueConnection() else { return }
                if var lifecycleParser {
                    let remaining = lifecycleParser.finish()
                    if !remaining.isEmpty {
                        _ = await writeOutput(remaining)
                    }
                }

                var sessionExists: Bool?
                if lastLifecycleEvent == nil, let lifecycle = startup?.tmuxLifecycle {
                    do {
                        let output = try await transport.execute(
                            lifecycle.presenceProbe.command,
                            .seconds(8)
                        )
                        sessionExists = lifecycle.presenceProbe.sessionExists(in: output)
                    } catch {
                        logger.warning(
                            "Unable to verify tmux session after shell exit: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                let endReason = TerminalShellEndReason.resolve(
                    tmuxLifecycle: startup?.tmuxLifecycle,
                    markerEvent: lastLifecycleEvent,
                    sessionExists: sessionExists
                )
                logger.info("SSH shell ended: \(String(describing: endReason), privacy: .public)")
                await onProcessExit(shell.id, endReason)
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard await shouldContinueConnection() else { return }
                lastError = error
                logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    guard !Task.isCancelled else { return }
                    guard await shouldContinueConnection() else { return }
                    if shouldReset {
                        logger.warning("Resetting SSH client before retrying connection")
                        await transport.disconnect()
                        guard !Task.isCancelled else { return }
                        guard await shouldContinueConnection() else { return }
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }

        if let lastError {
            guard await shouldContinueConnection() else { return }
            await onFailure(lastError)
        }
    }
}
