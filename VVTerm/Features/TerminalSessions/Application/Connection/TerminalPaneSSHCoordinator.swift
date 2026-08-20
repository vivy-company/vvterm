import Foundation
import os.log

@MainActor
final class TerminalPaneSSHCoordinator {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let sshClient: SSHClient
    let tabManager: TerminalTabManager

    private let richPasteRuntime: TerminalRichPasteRuntime
    private let failureOutput: @MainActor @Sendable (TerminalConnectionFailure) -> Data?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHPane")

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        tabManager: TerminalTabManager,
        failureOutput: @escaping @MainActor @Sendable (TerminalConnectionFailure) -> Data?
    ) {
        self.paneId = paneId
        self.server = server
        self.credentials = credentials
        self.sshClient = sshClient
        self.tabManager = tabManager
        self.failureOutput = failureOutput
        self.richPasteRuntime = tabManager.richPasteRuntimeStore.runtime(
            for: paneId,
            tabManager: tabManager
        )
    }

    @MainActor
    func installRichPasteInterception(on terminal: any TerminalSurface) {
        richPasteRuntime.install(on: terminal)
    }

    @MainActor
    func sendToSSH(_ data: Data) {
        tabManager.transportCoordinator.sendSSHInput(data, for: paneId)
    }

    @MainActor
    func handleResize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        tabManager.transportCoordinator.resizeSSH(
            for: paneId,
            cols: cols,
            rows: rows,
            pixelSize: pixelSize
        )
    }

    func startSSHConnection(terminal: any TerminalSurface) {
        let paneId = self.paneId
        if tabManager.transportCoordinator.activeSSHRoute(for: paneId) != nil {
            tabManager.updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let logger = self.logger
        let failureOutput = self.failureOutput
        let transport = SSHConnectionRunnerTransport.live(client: sshClient)
        let initialTerminalState = Self.initialTerminalState(for: terminal)
        let hasEstablishedConnection = tabManager.sessionState
            .paneState(for: paneId)?.hasEstablishedConnection == true
        guard tabManager.transportCoordinator.startSSHConnectionTask(
            for: paneId,
            server: server,
            client: sshClient,
            operation: { [weak terminal] context in
                await Self.runConnection(
                    server: server,
                    credentials: credentials,
                    sshClient: sshClient,
                    transport: transport,
                    initialTerminalState: initialTerminalState,
                    context: context,
                    hasEstablishedConnection: hasEstablishedConnection,
                    logger: logger,
                    writeOutput: { [weak terminal] data in
                        guard context.isCurrent(), let terminal else { return false }
                        terminal.receiveTerminalOutput(data)
                        return true
                    },
                    reportFailure: { [weak terminal] failure in
                        guard context.isCurrent() else { return }
                        if let data = failureOutput(failure) {
                            terminal?.receiveTerminalOutput(data)
                        }
                    }
                )
            }
        ) else {
            if tabManager.transportCoordinator.activeSSHRoute(for: paneId) != nil {
                tabManager.updatePaneState(paneId, connectionState: .connected)
            }
            logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
            return
        }
    }

    private static func runConnection(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        transport: SSHConnectionRunnerTransport,
        initialTerminalState: SSHConnectionInitialTerminalState,
        context: TerminalSSHConnectionContext,
        hasEstablishedConnection: Bool,
        logger: Logger,
        writeOutput: @MainActor @escaping @Sendable (Data) -> Bool,
        reportFailure: @MainActor @escaping @Sendable (TerminalConnectionFailure) -> Void
    ) async {
        await SSHConnectionRunner.run(
            server: server,
            credentials: credentials,
            transport: transport,
            initialTerminalState: initialTerminalState,
            logger: logger,
            shouldContinueConnection: context.isCurrent,
            onAttempt: { attempt in
                context.updateConnectionState(
                    TerminalConnectionAttemptPolicy.state(
                        attempt: attempt,
                        hasEstablishedConnection: hasEstablishedConnection
                    )
                )
            },
            startupPlan: context.startupPlan,
            restoreMoshShell: context.restoreMoshShell,
            registerShell: { shell in
                guard await context.registerShell(shell) else { return false }
                context.updateConnectionState(.connected)
                if shell.origin == .fresh, let cwd = context.workingDirectory() {
                    await applyWorkingDirectory(
                        cwd,
                        shellId: shell.id,
                        sshClient: sshClient,
                        logger: logger
                    )
                }
                if shell.transport == .mosh {
                    await context.persistMoshCheckpoint(shell.id)
                }
                return true
            },
            onTitleChange: context.updateTitle,
            writeOutput: writeOutput,
            shouldResetClient: { sshError in
                switch sshError {
                case .notConnected, .connectionFailed, .socketError, .timeout:
                    return true
                case .channelOpenFailed, .shellRequestFailed:
                    let hasOtherRegistrations = await context.hasOtherRegistrations()
                    return !hasOtherRegistrations
                case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyApprovalRequired, .hostKeyVerificationFailed, .moshServerMissing, .moshServerRuntimeBroken, .moshBootstrapFailed, .moshSessionFailed, .moshInvalidEndpoint, .moshUDPTimeout, .moshClientSessionFailed, .outputLimitExceeded, .unknown:
                    return false
                }
            },
            onProcessExit: context.handleShellEnd,
            onFailure: { error in
                guard context.isCurrent() else { return }
                let failure = TerminalConnectionFailure.transport(error)
                reportFailure(failure)
                context.handleFailure(failure)
            }
        )
    }

    private static func initialTerminalState(
        for terminal: any TerminalSurface
    ) -> SSHConnectionInitialTerminalState {
        let geometry = terminal.terminalGeometry
        return SSHConnectionInitialTerminalState(
            columns: geometry?.columns ?? 80,
            rows: geometry?.rows ?? 24,
            pixelSize: geometry?.pixelSize
        )
    }

    private static func applyWorkingDirectory(
        _ cwd: String,
        shellId: UUID,
        sshClient: SSHClient,
        logger: Logger
    ) async {
        let environment = await sshClient.remoteEnvironment()
        guard environment.shellProfile.family != .unknown else { return }
        let restorePlan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: cwd,
            environment: environment
        )
        guard case .command(let command) = restorePlan else {
            if case .keepDefault(let reason) = restorePlan {
                logger.warning(
                    "Keeping the default remote directory [reason: \(reason.rawValue, privacy: .public)]"
                )
            }
            return
        }
        guard let payload = command.data(using: .utf8) else { return }
        try? await sshClient.write(payload, to: shellId)
    }
}
