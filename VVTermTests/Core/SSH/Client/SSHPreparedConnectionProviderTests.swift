import Darwin
import Foundation
import Testing
@testable import VVTerm

private nonisolated final class SSHPreparationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<any SSHPreparedConnection, Never>?

    var didEnter: Bool { lock.withLock { waiter != nil } }

    func prepare() async -> any SSHPreparedConnection {
        await withCheckedContinuation { continuation in
            lock.withLock { waiter = continuation }
        }
    }

    func release(_ connection: any SSHPreparedConnection) {
        let continuation = lock.withLock {
            let previous = waiter
            waiter = nil
            return previous
        }
        continuation?.resume(returning: connection)
    }
}

private actor SSHPreparationRequestRecorder {
    private(set) var requests: [SSHPreparedConnectionRequest] = []
    func record(_ request: SSHPreparedConnectionRequest) { requests.append(request) }
}

@MainActor
struct SSHPreparedConnectionProviderTests {
    private enum PreparationError: Error { case rejected }

    @Test
    func providerGetsTheExactProfileClusterNodeAndLogin() async throws {
        let recorder = SSHPreparationRequestRecorder()
        let client = SSHClient.testing(prepareConnection: { request in
            await recorder.record(request)
            throw PreparationError.rejected
        })
        let server = try makeServer()
        let configuration = try #require(server.teleportConfiguration)

        do {
            _ = try await client.connect(to: server, credentials: ServerCredentials(serverId: server.id))
            Issue.record("A rejected provider must not open a direct SSH connection")
        } catch PreparationError.rejected {}

        #expect(await recorder.requests == [SSHPreparedConnectionRequest(
            profileID: configuration.profile.identifier,
            clusterName: "cluster-a", nodeID: "node-a", login: "alice"
        )])
        #expect(await client.lifecyclePhase == .failed)
        await client.disconnect()
    }

    @Test
    func providerResultAfterTimeoutClosesWithoutTransferringTheSocket() async throws {
        let barrier = SSHPreparationBarrier()
        let client = SSHClient.testing(connectTimeout: .milliseconds(50), prepareConnection: { _ in
            await barrier.prepare()
        })
        let server = try makeServer()
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        guard descriptors[0] >= 0 else { return }
        defer { Darwin.close(descriptors[1]) }
        let owner = SSHPreparedConnectionSpy(descriptor: descriptors[0])

        let attempt = Task {
            try await client.connect(to: server, credentials: ServerCredentials(serverId: server.id))
        }
        defer { barrier.release(owner); attempt.cancel() }
        try await HardOperationDeadline.run(timeout: .seconds(2)) {
            while !barrier.didEnter { try await Task.sleep(for: .milliseconds(1)) }
        }
        do {
            _ = try await HardOperationDeadline.run(timeout: .seconds(2)) { try await attempt.value }
            Issue.record("A stalled provider must reach the connection deadline")
        } catch SSHError.timeout {}
        barrier.release(owner)
        try await HardOperationDeadline.run(timeout: .seconds(2)) {
            while !owner.didCloseAfterDescriptor { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(!owner.transferred)
        #expect(fcntl(descriptors[0], F_GETFD) == -1)
        await client.disconnect()
    }

    private func makeServer() throws -> Server {
        let profile = try TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice")
        return Server(
            workspaceId: UUID(), name: "Teleport test", host: "must-not-dial.invalid", port: 3022,
            username: "alice", connectionMode: .teleport, authMethod: nil,
            teleportConfiguration: try TeleportServerConfiguration(
                profile: profile, clusterName: "cluster-a", nodeID: "node-a"
            )
        )
    }
}
