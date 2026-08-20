import Foundation
import Darwin
import os.log
import MoshCore
import MoshBootstrap

// MARK: - SSH Client using libssh2

actor SSHClient {
    struct ConnectingState {
        let id: UUID
        let key: String
        let task: Task<SSHSession, Error>
        var pendingSession: SSHSession?
        let startupTrace: SSHStartupTrace
    }

    struct ConnectedState {
        let id: UUID
        let key: String
        var server: Server
        let session: SSHSession
        var remoteEnvironment: RemoteEnvironment?
        var remoteTerminalType: RemoteTerminalType?
        let startupTrace: SSHStartupTrace
    }

    struct AbortedState {
        let operationID: UUID?
        let session: SSHSession?
        let connectTask: Task<SSHSession, Error>?
    }

    struct DisconnectOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    enum Lifecycle {
        case disconnected
        case connecting(ConnectingState)
        case connected(ConnectedState)
        case disconnecting(DisconnectOperation)
        case failed
        case aborted(AbortedState)
    }

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSH")
    private var keepAliveTask: Task<Void, Never>?
    var lifecycle: Lifecycle = .disconnected
    var moshRuntimeGeneration = UUID()
    var moshShells: [UUID: MoshShellRuntime] = [:]
    var pendingMoshServerLeases: [UUID: RemoteMoshServerLease] = [:]
    private let cloudflareTransportManager = CloudflareTransportManager()
    let moshStartupTimeout: Duration = .seconds(8)
    private let connectTimeout: Duration
    private let disconnectTimeout: Duration = .seconds(4)
    let execTimeout: Duration = .seconds(20)
    let uploadTimeout: Duration = .seconds(60)
    private let runtimeSettings: SSHRuntimeSettings
    private let hostKeyVerifier: any SSHHostKeyVerifying
    let moshBootstrap: any SSHMoshBootstrapping

    init(
        connectTimeout: Duration = .seconds(30),
        runtimeSettings: SSHRuntimeSettings,
        hostKeyVerifier: any SSHHostKeyVerifying,
        moshBootstrap: any SSHMoshBootstrapping
    ) {
        self.connectTimeout = connectTimeout
        self.runtimeSettings = runtimeSettings
        self.hostKeyVerifier = hostKeyVerifier
        self.moshBootstrap = moshBootstrap
    }

    #if DEBUG
    func runtimeSettingsForTesting() -> SSHRuntimeSettings {
        runtimeSettings
    }

    func hostKeyDecisionForTesting(
        _ candidate: SSHHostKeyCandidate
    ) -> SSHHostKeyVerificationDecision {
        hostKeyVerifier.verify(candidate)
    }

    func bootstrapMoshForTesting(
        execute: @escaping SSHMoshCommandExecutor
    ) async throws -> MoshServerConnectInfo {
        try await moshBootstrap.bootstrapConnectInfo(
            terminalType: .xterm256Color,
            startCommand: nil,
            portRange: 60_001...61_000,
            execute: execute
        )
    }

    func terminateMoshForTesting(
        pid: Int32,
        execute: @escaping SSHMoshCommandExecutor
    ) async {
        await moshBootstrap.terminateMoshServer(pid: pid, execute: execute)
    }
    #endif

    /// Check if the client has been aborted
    var isAborted: Bool {
        switch lifecycle {
        case .aborted, .disconnecting:
            return true
        case .disconnected, .connecting, .connected, .failed:
            return false
        }
    }

    var lifecyclePhase: LifecyclePhase {
        switch lifecycle {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        case .failed:
            return .failed
        case .aborted:
            return .aborted
        }
    }

    var session: SSHSession? {
        guard case .connected(let state) = lifecycle else { return nil }
        return state.session
    }

    var connectedServer: Server? {
        guard case .connected(let state) = lifecycle else { return nil }
        return state.server
    }

    var startupTrace: SSHStartupTrace? {
        switch lifecycle {
        case .connecting(let state):
            return state.startupTrace
        case .connected(let state):
            return state.startupTrace
        case .disconnected, .disconnecting, .failed, .aborted:
            return nil
        }
    }

    func probeLiveTransport(
        shellId: UUID,
        transport: ShellTransport
    ) async -> Bool {
        if transport == .mosh {
            guard let runtime = moshShells[shellId] else { return false }
            if case .running = await runtime.session.state {
                return true
            }
            return false
        }

        guard let session else { return false }
        let marker = "__VVTERM_WAKE_PROBE_\(UUID().uuidString)__"
        do {
            let output = try await HardOperationDeadline.run(
                timeout: .seconds(3),
                onTimeout: { session.abort() },
                operation: { try await session.execute("echo \(marker)") }
            )
            return output.contains(marker)
        } catch {
            return false
        }
    }

    /// Interrupts an active or pending transport before bounded cleanup starts.
    func abortConnection() {
        moshRuntimeGeneration = UUID()
        switch lifecycle {
        case .connecting(let state):
            state.task.cancel()
            state.pendingSession?.abort()
            lifecycle = .aborted(
                AbortedState(
                    operationID: state.id,
                    session: state.pendingSession,
                    connectTask: state.task
                )
            )
        case .connected(let state):
            state.session.abort()
            lifecycle = .aborted(
                AbortedState(operationID: state.id, session: state.session, connectTask: nil)
            )
        case .disconnecting:
            break
        case .disconnected, .failed, .aborted:
            lifecycle = .aborted(
                AbortedState(operationID: nil, session: nil, connectTask: nil)
            )
        }
    }

    // MARK: - Connection

    func connect(to server: Server, credentials: ServerCredentials) async throws -> SSHSession {
        let key = connectionKey(for: server)

        connectionPreparation: while true {
            try Task.checkCancellation()

            switch lifecycle {
            case .disconnecting(let operation):
                await operation.task.value

            case .aborted(let state) where state.session != nil || state.connectTask != nil:
                await disconnect()

            case .connected(let state):
                let transportIsConnected = await state.session.isConnected
                guard case .connected(let currentState) = lifecycle,
                      currentState.id == state.id,
                      currentState.session === state.session else {
                    continue
                }

                switch SSHConnectedSessionPolicy.action(
                    existingConnectionKey: state.key,
                    requestedConnectionKey: key,
                    transportIsConnected: transportIsConnected
                ) {
                case .reuse:
                    var updatedState = currentState
                    updatedState.server = server
                    lifecycle = .connected(updatedState)
                    return updatedState.session

                case .recover:
                    state.session.abort()
                    lifecycle = .aborted(
                        AbortedState(operationID: state.id, session: state.session, connectTask: nil)
                    )
                    await disconnect()

                case .reject:
                    throw SSHError.connectionFailed("SSH client already connected")
                }

            case .connecting(let state) where state.key == key:
                return try await resolveConnection(
                    operationID: state.id,
                    key: key,
                    server: server,
                    task: state.task
                )

            case .connecting:
                throw SSHError.connectionFailed("SSH client already connected")

            case .disconnected, .failed, .aborted:
                break connectionPreparation
            }
        }

        let startupTrace = SSHStartupTrace(logger: logger)
        let operationID = UUID()
        let task = Task {
            try await performConnectionAttempt(
                operationID: operationID,
                server: server,
                credentials: credentials,
                startupTrace: startupTrace
            )
        }
        lifecycle = .connecting(
            ConnectingState(
                id: operationID,
                key: key,
                task: task,
                pendingSession: nil,
                startupTrace: startupTrace
            )
        )
        return try await resolveConnection(
            operationID: operationID,
            key: key,
            server: server,
            task: task
        )
    }

    private func connectionKey(for server: Server) -> String {
        "\(server.host):\(server.port):\(server.username):\(server.connectionMode):\(server.authMethod):\(server.cloudflareAccessMode?.rawValue ?? "none"):\(server.cloudflareTeamDomainOverride ?? "")"
    }

    private func performConnectionAttempt(
        operationID: UUID,
        server: Server,
        credentials: ServerCredentials,
        startupTrace: SSHStartupTrace
    ) async throws -> SSHSession {
        logger.info(
            "Connecting to \(server.host, privacy: .private(mask: .hash)):\(server.port, privacy: .private(mask: .hash)) [mode: \(server.connectionMode.rawValue, privacy: .public)]"
        )
        logger.info("Auth method: \(String(describing: server.authMethod)), password present: \(credentials.password != nil)")
        let transportToken = startupTrace.begin(.transportPreparation)

        var dialHost = server.host
        var dialPort = server.port

        if server.connectionMode == .cloudflare {
            let localPort = try await cloudflareTransportManager.connect(
                server: server,
                credentials: credentials
            )
            dialHost = "127.0.0.1"
            dialPort = Int(localPort)
            logger.info("Using Cloudflare local tunnel endpoint \(dialHost):\(dialPort)")
        } else {
            await disconnectCloudflareTransport(reason: "pre-connect cleanup")
        }

        guard case .connecting(let currentState) = lifecycle,
              currentState.id == operationID,
              !Task.isCancelled else {
            if shouldCleanupConnectionTransport(for: operationID) {
                await disconnectCloudflareTransport(reason: "cancelled transport preparation")
            }
            throw CancellationError()
        }
        startupTrace.end(transportToken, detail: server.connectionMode.rawValue)

        let config = SSHSessionConfig(
            host: server.host,
            port: server.port,
            dialHost: dialHost,
            dialPort: dialPort,
            hostKeyHost: server.host,
            hostKeyPort: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            credentials: credentials,
            keepAlive: runtimeSettings.keepAlive
        )
        let pendingSession = SSHSession(
            config: config,
            hostKeyVerifier: hostKeyVerifier,
            startupTrace: startupTrace
        )

        guard case .connecting(var connectingState) = lifecycle,
              connectingState.id == operationID else {
            pendingSession.abort()
            throw CancellationError()
        }
        connectingState.pendingSession = pendingSession
        lifecycle = .connecting(connectingState)

        do {
            try await HardOperationDeadline.run(
                timeout: connectTimeout,
                onTimeout: {
                    startupTrace.recordOnce(
                        .connectionDeadline,
                        outcome: "timeout"
                    )
                    pendingSession.abort()
                }
            ) {
                try await pendingSession.connect()
            }
            try Task.checkCancellation()
            return pendingSession
        } catch {
            pendingSession.abort()
            Task.detached(priority: .utility) {
                await pendingSession.disconnect()
            }
            if error is HardOperationDeadlineError {
                throw SSHError.timeout
            }
            throw error
        }
    }

    private func resolveConnection(
        operationID: UUID,
        key: String,
        server: Server,
        task: Task<SSHSession, Error>
    ) async throws -> SSHSession {
        do {
            let connectedSession = try await task.value
            guard !Task.isCancelled, !task.isCancelled else {
                connectedSession.abort()
                await connectedSession.disconnect()
                if case .connecting(let state) = lifecycle, state.id == operationID {
                    lifecycle = .aborted(AbortedState(
                        operationID: operationID,
                        session: connectedSession,
                        connectTask: nil
                    ))
                }
                if shouldCleanupConnectionTransport(for: operationID) {
                    await disconnectCloudflareTransport(reason: "connect cancellation")
                }
                throw CancellationError()
            }

            switch lifecycle {
            case .connecting(let state) where state.id == operationID:
                lifecycle = .connected(
                    ConnectedState(
                        id: operationID,
                        key: key,
                        server: server,
                        session: connectedSession,
                        remoteEnvironment: nil,
                        remoteTerminalType: nil,
                        startupTrace: state.startupTrace
                    )
                )
                startKeepAlive(policy: connectedSession.config.keepAlive)
                logger.info("Connected to \(server.host, privacy: .private(mask: .hash))")
                return connectedSession
            case .connected(var state)
                where state.id == operationID && state.session === connectedSession:
                state.server = server
                lifecycle = .connected(state)
                return connectedSession
            default:
                connectedSession.abort()
                await connectedSession.disconnect()
                if shouldCleanupConnectionTransport(for: operationID) {
                    await disconnectCloudflareTransport(reason: "stale connect completion")
                }
                throw CancellationError()
            }
        } catch {
            let ownsFailure: Bool
            if case .connecting(let state) = lifecycle, state.id == operationID {
                ownsFailure = true
            } else {
                ownsFailure = false
            }
            if shouldCleanupConnectionTransport(for: operationID) {
                await disconnectCloudflareTransport(reason: "connect failure")
            }
            if ownsFailure,
               case .connecting(let state) = lifecycle,
               state.id == operationID {
                lifecycle = .failed
            }
            if server.connectionMode == .cloudflare,
               case SSHError.connectionFailed(let message) = error,
               message.contains("SSH handshake failed: -13") {
                throw SSHError.cloudflareTunnelFailed(
                    String(
                        localized: "Cloudflare tunnel connected, but SSH handshake was closed by the upstream target. Verify Access policy and service token scope."
                    )
                )
            }
            throw error
        }
    }

    private func shouldCleanupConnectionTransport(for operationID: UUID) -> Bool {
        switch lifecycle {
        case .connecting(let state):
            return state.id == operationID
        case .connected(let state):
            return state.id == operationID
        case .aborted(let state):
            return state.operationID == operationID
        case .disconnected, .disconnecting, .failed:
            return true
        }
    }

    func disconnect() async {
        if case .disconnecting(let operation) = lifecycle {
            await operation.task.value
            return
        }

        moshRuntimeGeneration = UUID()

        let activeSession: SSHSession?
        switch lifecycle {
        case .connecting(let state):
            state.task.cancel()
            state.pendingSession?.abort()
            activeSession = state.pendingSession
        case .connected(let state):
            activeSession = state.session
        case .aborted(let state):
            state.connectTask?.cancel()
            state.session?.abort()
            activeSession = state.session
        case .disconnected, .disconnecting, .failed:
            activeSession = nil
        }

        let pendingMoshServerLeases = Array(self.pendingMoshServerLeases.values)
        self.pendingMoshServerLeases.removeAll()
        let activeMoshShells = Array(moshShells.values)
        moshShells.removeAll()

        keepAliveTask?.cancel()
        keepAliveTask = nil

        let operationID = UUID()
        let disconnectTimeout = self.disconnectTimeout
        let cloudflareTransportManager = self.cloudflareTransportManager
        let logger = self.logger
        let task = Task {
            let cleanupFinished = await SSHClient.cleanupPendingMoshServerLeases(
                pendingMoshServerLeases
            )
            if !cleanupFinished {
                logger.warning(
                    "Pending remote mosh-server cleanup exceeded the disconnect coordination window"
                )
            }

            for runtime in activeMoshShells {
                runtime.streamTask.cancel()
                await runtime.output.cancel()
                await runtime.session.stop()
            }

            await SSHClient.disconnectSSHSession(
                activeSession,
                timeout: disconnectTimeout,
                logger: logger
            )
            await SSHClient.disconnectCloudflareTransport(
                cloudflareTransportManager,
                reason: "client disconnect",
                logger: logger
            )
            self.finishDisconnect(operationID: operationID)
            logger.info("Disconnected")
        }
        lifecycle = .disconnecting(DisconnectOperation(id: operationID, task: task))
        await task.value
    }

    // MARK: - Keep Alive

    private func startKeepAlive(policy: SSHKeepAlivePolicy) {
        keepAliveTask?.cancel()
        keepAliveTask = nil

        guard case .enabled(let intervalSeconds) = policy else { return }

        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await session?.sendKeepAlive()
            }
        }
    }

    private func finishDisconnect(operationID: UUID) {
        guard case .disconnecting(let operation) = lifecycle,
              operation.id == operationID else {
            return
        }
        lifecycle = .aborted(
            AbortedState(operationID: nil, session: nil, connectTask: nil)
        )
    }

    nonisolated static func cleanupPendingMoshServerLeases(
        _ leases: [RemoteMoshServerLease]
    ) async -> Bool {
        guard !leases.isEmpty else { return true }

        // This task is deliberately unstructured so cancellation of the caller
        // cannot shorten the cleanup window before the remote PID is known.
        return await Task {
            do {
                try await runWithDeadline(RemoteMoshManager.disconnectCleanupTimeout) {
                    await withTaskGroup(of: Void.self) { group in
                        for lease in leases {
                            group.addTask {
                                await lease.cleanup()
                            }
                        }
                    }
                }
                return true
            } catch {
                // Cleanup continues in its unstructured operation task, but the
                // disconnect path does not wait beyond this coordination bound.
                return false
            }
        }.value
    }

    private nonisolated static func disconnectSSHSession(
        _ activeSession: SSHSession?,
        timeout: Duration,
        logger: Logger
    ) async {
        guard let activeSession else { return }

        do {
            try await runWithDeadline(
                timeout,
                onTimeout: {
                    logger.warning("Timed out while disconnecting SSH session; aborting socket")
                    activeSession.abort()
                }
            ) {
                await activeSession.disconnect()
            }
        } catch SSHError.timeout {
            // The deadline callback already aborted the socket.
        } catch {
            activeSession.abort()
        }
    }

    private func disconnectCloudflareTransport(reason: String) async {
        await SSHClient.disconnectCloudflareTransport(
            cloudflareTransportManager,
            reason: reason,
            logger: logger
        )
    }

    private nonisolated static func disconnectCloudflareTransport(
        _ manager: CloudflareTransportManager,
        reason: String,
        logger: Logger
    ) async {
        await manager.disconnect()
        logger.debug("Cloudflare disconnect coordination completed (\(reason, privacy: .public))")
    }

    // MARK: - State

    var isConnected: Bool {
        get async {
            await session?.isConnected ?? false
        }
    }

    nonisolated static func runWithDeadline<T: Sendable>(
        _ timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await HardOperationDeadline.run(
                timeout: timeout,
                onTimeout: onTimeout,
                operation: operation
            )
        } catch is HardOperationDeadlineError {
            throw SSHError.timeout
        }
    }

    /// Allows slow large transfers while keeping one operation bounded.
    /// The timeout assumes at least 64 KiB/s and is capped at 24 hours.
    nonisolated static func streamTransferTimeout(for byteCount: UInt64) -> Duration {
        let secondsForBytes = byteCount / UInt64(64 * 1_024)
        let secondsWithSetup = secondsForBytes.addingReportingOverflow(120)
        let requestedSeconds = secondsWithSetup.overflow ? UInt64.max : secondsWithSetup.partialValue
        return .seconds(Int64(min(requestedSeconds, 86_400)))
    }


}
