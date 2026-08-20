#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct SSHConnectionDeadlineTests {
    @Test
    func blockedHandshakeIsAbortedAtTheHardDeadline() async throws {
        let listener = try LoopbackListener()
        let client = SSHClient.testing(connectTimeout: .milliseconds(100))
        let server = Server(
            workspaceId: UUID(),
            name: "Blocked handshake",
            host: "127.0.0.1",
            port: listener.port,
            username: "test",
            authMethod: .password
        )
        let credentials = ServerCredentials(serverId: server.id, password: "unused")
        let startedAt = ContinuousClock.now

        do {
            _ = try await client.connect(to: server, credentials: credentials)
            Issue.record("Expected the blocked SSH handshake to time out")
        } catch let error as SSHError {
            guard case .timeout = error else {
                Issue.record("Expected SSHError.timeout, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected SSHError.timeout, received \(error)")
        }

        #expect(startedAt.duration(to: .now) < .seconds(2))
        #expect(await client.lifecyclePhase == .failed)
        listener.close()
        await client.disconnect()
        #expect(await client.lifecyclePhase == .aborted)
    }

    @Test
    func abortDuringHandshakeRejectsStaleCompletionAndAllowsCleanup() async throws {
        let listener = try LoopbackListener()
        let client = SSHClient.testing(connectTimeout: .seconds(10))
        let server = Server(
            workspaceId: UUID(),
            name: "Aborted handshake",
            host: "127.0.0.1",
            port: listener.port,
            username: "test",
            authMethod: .password
        )
        let credentials = ServerCredentials(serverId: server.id, password: "unused")
        let connection = Task {
            try await client.connect(to: server, credentials: credentials)
        }

        for _ in 0..<1_000 {
            if await client.lifecyclePhase == .connecting { break }
            await Task.yield()
        }
        #expect(await client.lifecyclePhase == .connecting)

        await client.abortConnection()
        #expect(await client.lifecyclePhase == .aborted)
        #expect(await client.isAborted)

        do {
            _ = try await connection.value
            Issue.record("Expected the aborted handshake to fail")
        } catch is CancellationError {
            // Expected.
        } catch let error as SSHError {
            if case .notConnected = error {
                // Expected if the socket observes the abort first.
            } else {
                Issue.record("Expected cancellation or notConnected, received \(error)")
            }
        } catch {
            Issue.record("Expected cancellation or notConnected, received \(error)")
        }

        #expect(await client.lifecyclePhase == .aborted)
        listener.close()
        await client.disconnect()
        #expect(await client.lifecyclePhase == .aborted)
    }
}
#endif
