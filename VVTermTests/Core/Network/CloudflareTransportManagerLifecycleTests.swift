import Foundation
import Cloudflared
import Testing
@testable import VVTerm

struct CloudflareTransportManagerLifecycleTests {
    @Test
    func replacementRejectsThePreviousSessionsLatePort() async throws {
        let sessions = CloudflareTransportSessionStore()
        let subject = CloudflareTransportManager(makeSession: { _ in sessions.makeSession() })
        let server = makeServer()
        let credentials = makeCredentials(serverID: server.id)

        let firstConnect = Task {
            try await subject.connect(server: server, credentials: credentials)
        }
        let firstSession = await sessions.session(at: 0)
        await firstSession.waitUntilConnectStarts()

        let secondConnect = Task {
            try await subject.connect(server: server, credentials: credentials)
        }
        let secondSession = await sessions.session(at: 1)
        await secondSession.waitUntilConnectStarts()

        await secondSession.succeed(port: 2_222)
        #expect(try await secondConnect.value == 2_222)

        await firstSession.succeed(port: 1_111)
        await #expect(throws: CancellationError.self) {
            try await firstConnect.value
        }

        await subject.disconnect()
        #expect(await firstSession.disconnectCount == 1)
        #expect(await secondSession.disconnectCount == 1)
    }

    @Test
    func disconnectInvalidatesAConnectThatIgnoresCancellation() async throws {
        let sessions = CloudflareTransportSessionStore()
        let subject = CloudflareTransportManager(makeSession: { _ in sessions.makeSession() })
        let server = makeServer()
        let credentials = makeCredentials(serverID: server.id)

        let connect = Task {
            try await subject.connect(server: server, credentials: credentials)
        }
        let session = await sessions.session(at: 0)
        await session.waitUntilConnectStarts()

        await subject.disconnect()
        await session.succeed(port: 2_222)

        await #expect(throws: CancellationError.self) {
            try await connect.value
        }
        #expect(await session.disconnectCount == 1)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Cloudflare Test",
            host: "ssh.example.com",
            username: "root",
            connectionMode: .cloudflare,
            authMethod: .password,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.cloudflareaccess.com"
        )
    }

    private func makeCredentials(serverID: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverID,
            credentialBinding: nil,
            password: "password",
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )
    }
}

private final class CloudflareTransportSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ControlledCloudflareTransportSession] = []

    func makeSession() -> CloudflareTransportSession {
        let session = ControlledCloudflareTransportSession()
        lock.withLock {
            sessions.append(session)
        }
        return session.operations
    }

    func session(at index: Int) async -> ControlledCloudflareTransportSession {
        while true {
            if let session = lock.withLock({ sessions.indices.contains(index) ? sessions[index] : nil }) {
                return session
            }
            await Task.yield()
        }
    }
}

private actor ControlledCloudflareTransportSession {
    private var connectContinuation: CheckedContinuation<UInt16, any Error>?
    private var connectStarted = false
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var disconnectCount = 0

    nonisolated var operations: CloudflareTransportSession {
        CloudflareTransportSession(
            connect: { hostname, method in
                try await self.connect(hostname: hostname, method: method)
            },
            disconnect: {
                await self.disconnect()
            }
        )
    }

    func waitUntilConnectStarts() async {
        guard !connectStarted else { return }
        await withCheckedContinuation { continuation in
            connectStartWaiters.append(continuation)
        }
    }

    func succeed(port: UInt16) {
        connectContinuation?.resume(returning: port)
        connectContinuation = nil
    }

    private func connect(hostname: String, method: Cloudflared.AuthMethod) async throws -> UInt16 {
        _ = hostname
        _ = method
        connectStarted = true
        let waiters = connectStartWaiters
        connectStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
        }
    }

    private func disconnect() {
        disconnectCount += 1
    }
}
