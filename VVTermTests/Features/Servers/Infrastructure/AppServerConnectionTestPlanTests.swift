import Foundation
import Testing
@testable import VVTerm

private actor ServerConnectionOperationRunnerFake: ServerConnectionOperationRunning {
    enum Behavior: Sendable {
        case run
        case cancel
        case hostKeyApprovalRequired
    }

    private let behavior: Behavior
    private let client = SSHClient.testing()
    private var callCount = 0

    init(behavior: Behavior = .run) {
        self.behavior = behavior
    }

    func runServerConnectionTest(
        server: Server,
        credentials: ServerCredentials,
        operation: @escaping @Sendable (SSHClient) async throws -> Void
    ) async throws {
        callCount += 1
        switch behavior {
        case .run:
            try await operation(client)
        case .cancel:
            throw CancellationError()
        case .hostKeyApprovalRequired:
            throw SSHError.hostKeyApprovalRequired
        }
    }

    func calls() -> Int {
        callCount
    }

    func clientIdentity() -> ObjectIdentifier {
        ObjectIdentifier(client)
    }
}

private actor ServerRemoteSystemDetectorFake: ServerRemoteSystemDetecting {
    private let result: RemoteSystemIdentity?
    private var clientIdentities: [ObjectIdentifier] = []

    init(result: RemoteSystemIdentity? = nil) {
        self.result = result
    }

    func detect(using client: SSHClient) async -> RemoteSystemIdentity? {
        clientIdentities.append(ObjectIdentifier(client))
        return result
    }

    func detectedClientIdentities() -> [ObjectIdentifier] {
        clientIdentities
    }
}

private actor ServerMoshConnectionTesterFake: ServerMoshConnectionTesting {
    private var testedPortRanges: [ClosedRange<Int>] = []

    func testServerConnection(
        using client: SSHClient,
        portRange: ClosedRange<Int>
    ) async throws {
        testedPortRanges.append(portRange)
    }

    func portRanges() -> [ClosedRange<Int>] {
        testedPortRanges
    }
}

private nonisolated struct ConnectionTestHostKeyRepositoryFake: ServerHostKeyRepository {
    private let challenge: KnownHostsManager.Challenge?

    init(challenge: KnownHostsManager.Challenge? = nil) {
        self.challenge = challenge
    }

    func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge? {
        challenge
    }

    func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool {
        false
    }

    func reject(_ challenge: KnownHostsManager.Challenge) {}
}

struct AppServerConnectionTestPlanTests {
    @Test(arguments: [false, true])
    func unsupportedSettingsNeverStartAConnectionTest(unknownMode: Bool) async {
        var server = makeServer(mode: unknownMode ? .unsupported("future") : .standard)
        server.transportConfiguration = .unsupported(type: "future", version: 1, settings: Data())
        let operations = ServerConnectionOperationRunnerFake()
        let tester = AppServerConnectionTester(
            connectionOperations: operations, remoteMosh: ServerMoshConnectionTesterFake(),
            remoteSystemDetector: ServerRemoteSystemDetectorFake(),
            hostKeys: ConnectionTestHostKeyRepositoryFake(), now: { .distantPast }
        )
        #expect(ServerConnectionTestPlan(server: server) == nil)
        let result = await tester.test(server: server, credentials: ServerCredentials(serverId: server.id))
        guard case .failure = result else {
            Issue.record("Unsupported settings must fail the test")
            return
        }
        #expect(await operations.calls() == 0)
    }

    @Test
    func teleportUsesOnlySSHAndNeverOffersAHostKeyApprovalOverride() throws {
        var server = makeServer(mode: .teleport)
        server.teleportConfiguration = try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "test"),
            clusterName: "test-cluster", nodeID: "test-node"
        )
        #expect(ServerConnectionTestPlan(server: server) == .sshOnly)
        #expect(ServerConnectionApprovalPolicy.requirement(
            for: SSHError.hostKeyApprovalRequired, server: server
        ) == nil)
    }

    @Test
    func standardUsesOnlyTheSSHProbe() {
        #expect(ServerConnectionTestPlan(server: makeServer(mode: .standard)) == .sshOnly)
    }

    @Test
    func tailscaleUsesOnlyTheSSHProbe() {
        #expect(ServerConnectionTestPlan(server: makeServer(mode: .tailscale)) == .sshOnly)
    }

    @Test
    func cloudflareUsesOnlyTheSSHProbe() {
        #expect(ServerConnectionTestPlan(server: makeServer(mode: .cloudflare)) == .sshOnly)
    }

    @Test
    func moshUsesTheBoundedBootstrapPortRange() {
        #expect(
            ServerConnectionTestPlan(server: makeServer(mode: .mosh))
                == .mosh(portRange: 60_001...61_000)
        )
    }

    @Test
    func eternalTerminalUsesItsConfiguredPortAndBoundsInvalidValues() {
        var server = makeServer(mode: .eternalTerminal)
        server.eternalTerminalPort = 22_022
        #expect(ServerConnectionTestPlan(server: server) == .eternalTerminal(port: 22_022))

        server.eternalTerminalPort = Int.max
        #expect(ServerConnectionTestPlan(server: server) == .eternalTerminal(port: 2_022))

        server.eternalTerminalPort = 0
        #expect(ServerConnectionTestPlan(server: server) == .eternalTerminal(port: 2_022))
    }

    @Test
    func hostKeyFailureRequiresApprovalForTheCurrentEndpoint() {
        let server = makeServer(mode: .standard)

        #expect(
            ServerConnectionApprovalPolicy.requirement(
                for: SSHError.hostKeyApprovalRequired,
                server: server
            ) == .hostKey(host: server.host, port: server.port)
        )
    }

    @Test
    func unrelatedFailureDoesNotRequestApproval() {
        #expect(
            ServerConnectionApprovalPolicy.requirement(
                for: SSHError.authenticationFailed,
                server: makeServer(mode: .standard)
            ) == nil
        )
    }

    @Test
    func testerUsesOnlyItsInjectedConnectionAndMoshOwners() async {
        let usedConnectionOperations = ServerConnectionOperationRunnerFake()
        let unusedConnectionOperations = ServerConnectionOperationRunnerFake()
        let usedMosh = ServerMoshConnectionTesterFake()
        let unusedMosh = ServerMoshConnectionTesterFake()
        let identity = RemoteSystemIdentity(kind: .ubuntu, displayName: "Ubuntu 24.04")
        let detector = ServerRemoteSystemDetectorFake(result: identity)
        let tester = AppServerConnectionTester(
            connectionOperations: usedConnectionOperations,
            remoteMosh: usedMosh,
            remoteSystemDetector: detector,
            hostKeys: ConnectionTestHostKeyRepositoryFake(),
            now: { .distantPast }
        )
        let server = makeServer(mode: .mosh)

        let result = await tester.test(
            server: server,
            credentials: ServerCredentials(serverId: server.id)
        )

        #expect(result == .successWithDetectedSystem(identity))
        #expect(await usedConnectionOperations.calls() == 1)
        #expect(await unusedConnectionOperations.calls() == 0)
        #expect(await usedMosh.portRanges() == [60_001...61_000])
        #expect(await unusedMosh.portRanges().isEmpty)
        let operationClientIdentity = await usedConnectionOperations.clientIdentity()
        #expect(
            await detector.detectedClientIdentities()
                == [operationClientIdentity]
        )
    }

    @Test
    func testerMapsInjectedOperationCancellationToCancelled() async {
        let server = makeServer(mode: .standard)
        let tester = AppServerConnectionTester(
            connectionOperations: ServerConnectionOperationRunnerFake(behavior: .cancel),
            remoteMosh: ServerMoshConnectionTesterFake(),
            remoteSystemDetector: ServerRemoteSystemDetectorFake(),
            hostKeys: ConnectionTestHostKeyRepositoryFake(),
            now: { .distantPast }
        )

        let result = await tester.test(
            server: server,
            credentials: ServerCredentials(serverId: server.id)
        )

        #expect(result == .cancelled)
    }

    @Test
    func unavailableHostKeyChallengeRemainsUnavailable() async {
        let server = makeServer(mode: .standard)
        let tester = AppServerConnectionTester(
            connectionOperations: ServerConnectionOperationRunnerFake(
                behavior: .hostKeyApprovalRequired
            ),
            remoteMosh: ServerMoshConnectionTesterFake(),
            remoteSystemDetector: ServerRemoteSystemDetectorFake(),
            hostKeys: ConnectionTestHostKeyRepositoryFake(),
            now: { .distantPast }
        )

        let result = await tester.test(
            server: server,
            credentials: ServerCredentials(serverId: server.id)
        )

        guard case .failure(let failure) = result else {
            Issue.record("The host-key error did not return a failure")
            return
        }
        #expect(failure.hostKeyChallenge == nil)
    }

    private func makeServer(mode: SSHConnectionMode) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 2222,
            username: "root",
            connectionMode: mode
        )
    }
}
