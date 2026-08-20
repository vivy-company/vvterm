import ETSession
import Foundation
import MoshBootstrap

extension KnownHostsManager: ServerHostKeyRepository {}

nonisolated protocol ServerConnectionOperationRunning: Sendable {
    func runServerConnectionTest(
        server: Server,
        credentials: ServerCredentials,
        operation: @escaping @Sendable (SSHClient) async throws -> Void
    ) async throws
}

nonisolated protocol ServerMoshConnectionTesting: Sendable {
    func testServerConnection(
        using client: SSHClient,
        portRange: ClosedRange<Int>
    ) async throws
}

extension SSHConnectionOperationService: ServerConnectionOperationRunning {
    func runServerConnectionTest(
        server: Server,
        credentials: ServerCredentials,
        operation: @escaping @Sendable (SSHClient) async throws -> Void
    ) async throws {
        try await withTemporaryConnection(
            server: server,
            credentials: credentials,
            operation: operation
        )
    }
}

extension RemoteMoshManager: ServerMoshConnectionTesting {
    func testServerConnection(
        using client: SSHClient,
        portRange: ClosedRange<Int>
    ) async throws {
        let connectInfo = try await bootstrapConnectInfo(
            using: client,
            startCommand: "exec true",
            portRange: portRange
        )
        await Self.terminateBootstrappedServer(pid: connectInfo.serverPID) { pid in
            await self.terminateMoshServer(
                pid: pid,
                execute: { command, timeout in
                    try await client.execute(command, timeout: timeout)
                }
            )
        }
    }
}

nonisolated enum ServerConnectionTestPlan: Equatable, Sendable {
    case sshOnly
    case mosh(portRange: ClosedRange<Int>)
    case eternalTerminal(port: UInt16)

    init(server: Server) {
        switch server.connectionMode {
        case .standard, .tailscale, .cloudflare:
            self = .sshOnly
        case .mosh:
            self = .mosh(portRange: 60_001...61_000)
        case .eternalTerminal:
            let port = server.eternalTerminalPort
            let resolvedPort: UInt16 = (1...Int(UInt16.max)).contains(port) ? UInt16(port) : 2_022
            self = .eternalTerminal(port: resolvedPort)
        }
    }
}

nonisolated enum ServerConnectionApprovalRequirement: Equatable, Sendable {
    case hostKey(host: String, port: Int)
}

nonisolated enum ServerConnectionApprovalPolicy {
    static func requirement(
        for error: Error,
        server: Server
    ) -> ServerConnectionApprovalRequirement? {
        if let sshError = error as? SSHError,
           case .hostKeyApprovalRequired = sshError {
            return .hostKey(host: server.host, port: server.port)
        }
        return nil
    }
}

extension ServerFormDependencies {
    static func live(
        credentials: any ServerCredentialRepository,
        hostKeys: any ServerHostKeyRepository,
        connectionOperations: any ServerConnectionOperationRunning,
        remoteMosh: any ServerMoshConnectionTesting,
        defaultTmuxEnabled: @escaping @MainActor () -> Bool,
        defaultTmuxStartupBehavior: @escaping @MainActor () -> TmuxStartupBehavior,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) -> Self {
        Self(
            credentials: credentials,
            connectionTester: AppServerConnectionTester(
                connectionOperations: connectionOperations,
                remoteMosh: remoteMosh,
                hostKeys: hostKeys,
                now: now
            ),
            hostKeys: hostKeys,
            defaultTmuxEnabled: defaultTmuxEnabled,
            defaultTmuxStartupBehavior: defaultTmuxStartupBehavior,
            now: now,
            makeID: makeID
        )
    }
}

nonisolated struct AppServerConnectionTester: ServerConnectionTesting {
    private let connectionOperations: any ServerConnectionOperationRunning
    private let remoteMosh: any ServerMoshConnectionTesting
    private let hostKeys: any ServerHostKeyRepository
    private let now: @Sendable () -> Date

    init(
        connectionOperations: any ServerConnectionOperationRunning,
        remoteMosh: any ServerMoshConnectionTesting,
        hostKeys: any ServerHostKeyRepository,
        now: @escaping @Sendable () -> Date
    ) {
        self.connectionOperations = connectionOperations
        self.remoteMosh = remoteMosh
        self.hostKeys = hostKeys
        self.now = now
    }

    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult {
        let plan = ServerConnectionTestPlan(server: server)
        do {
            try Task.checkCancellation()
            try await connectionOperations.runServerConnectionTest(
                server: server,
                credentials: credentials
            ) { client in
                try Task.checkCancellation()
                switch plan {
                case .sshOnly:
                    break
                case .mosh(let portRange):
                    try await remoteMosh.testServerConnection(
                        using: client,
                        portRange: portRange
                    )
                case .eternalTerminal(let port):
                    let session = ETTerminalSession(
                        host: server.host,
                        port: port,
                        bootstrapExecutor: SSHETBootstrapExecutor(connectedClient: client),
                        bootstrapOptions: SSHETBootstrapExecutor.bootstrapOptions
                    )
                    do {
                        try await session.connect()
                        await session.close()
                    } catch {
                        await session.close()
                        throw error
                    }
                }
            }
            try Task.checkCancellation()
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(failure(for: error, server: server))
        }
    }

    private func failure(for error: Error, server: Server) -> ServerConnectionTestFailure {
        let reason: ServerConnectionTestFailureReason
        if server.connectionMode == .eternalTerminal {
            reason = .eternalTerminal(
                failure: EternalTerminalVendorErrorMapper.failure(for: error),
                host: server.host,
                port: server.eternalTerminalPort
            )
        } else if server.connectionMode == .tailscale {
            reason = .tailscale(error.localizedDescription)
        } else {
            reason = .message(error.localizedDescription)
        }

        let requiresCloudflareOverrides: Bool
        let hostKeyChallenge: KnownHostsManager.Challenge?
        if let sshError = error as? SSHError,
           case .cloudflareConfigurationRequired = sshError {
            requiresCloudflareOverrides = true
        } else {
            requiresCloudflareOverrides = false
        }
        if let approval = ServerConnectionApprovalPolicy.requirement(for: error, server: server),
           case .hostKey(let host, let port) = approval {
            hostKeyChallenge = hostKeys.pendingChallenge(
                for: host,
                port: port,
                now: now()
            )
        } else {
            hostKeyChallenge = nil
        }

        return ServerConnectionTestFailure(
            reason: reason,
            requiresCloudflareOverrides: requiresCloudflareOverrides,
            hostKeyChallenge: hostKeyChallenge
        )
    }
}
