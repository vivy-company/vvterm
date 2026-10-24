import Darwin
import Foundation
import Testing
@testable import VVTerm

struct SSHPreparedConnectionTests {
    @Test
    func trustModesCannotNegotiateEachOthersHostKeyTypes() {
        let supported = [
            "ssh-ed25519-cert-v01@openssh.com", "ssh-ed25519",
            "rsa-sha2-512-cert-v01@openssh.com", "rsa-sha2-512",
            "ecdsa-sha2-nistp256",
            "future-cert-v02@openssh.com",
        ]
        #expect(SSHSession.hostKeyMethodPreference(supported: supported, requiresCertificate: true)
            == "ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512-cert-v01@openssh.com")
        #expect(SSHSession.hostKeyMethodPreference(supported: supported, requiresCertificate: false)
            == "ecdsa-sha2-nistp256,ssh-ed25519,rsa-sha2-512")
        #expect(SSHSession.hostKeyMethodPreference(supported: ["ssh-ed25519"], requiresCertificate: true) == nil)
        #expect(SSHSession.hostKeyMethodPreference(supported: [supported[0]], requiresCertificate: false) == nil)
    }

    @Test
    func disconnectDuringHandshakeStopsNativeWorkBeforeClosingProvider() async throws {
        try await checkHandshakeTeardown(cancel: false)
    }

    @Test
    func cancellationDuringHandshakeClosesTransferredSocket() async throws {
        try await checkHandshakeTeardown(cancel: true)
    }

    @Test
    func stalledPreparedHandshakeHasAnInternalDeadline() async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair.peer) }
        let owner = SSHPreparedConnectionSpy(descriptor: pair.client)
        let session = makeSession(owner: owner, timeout: 0.02)

        do {
            try await HardOperationDeadline.run(timeout: .seconds(2)) {
                try await session.connect()
            }
            Issue.record("A silent peer must not finish the SSH handshake")
        } catch SSHError.timeout {
            // The session's own deadline must end the attempt first.
        }
        try await waitForProviderClose(owner)
        #expect(fcntl(pair.client, F_GETFD) == -1)
        #expect(owner.didCloseAfterDescriptor)
    }

    private func checkHandshakeTeardown(cancel: Bool) async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair.peer) }
        let owner = SSHPreparedConnectionSpy(descriptor: pair.client)
        let session = makeSession(owner: owner)
        let attempt = Task { try await session.connect() }
        defer { attempt.cancel(); session.abort() }

        try await HardOperationDeadline.run(timeout: .seconds(2)) {
            while !owner.transferred {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        #expect(fcntl(pair.client, F_GETFL) & O_NONBLOCK != 0)
        if cancel {
            attempt.cancel()
        } else {
            await session.disconnect()
        }
        do {
            try await HardOperationDeadline.run(timeout: .seconds(2)) { try await attempt.value }
            Issue.record("An interrupted SSH handshake must fail")
        } catch is CancellationError {
            #expect(cancel)
        } catch SSHError.notConnected {
            #expect(!cancel)
        }
        try await waitForProviderClose(owner)
        #expect(fcntl(pair.client, F_GETFD) == -1)
        #expect(owner.didCloseAfterDescriptor)
        #expect(await session.hasBeenCleaned)
    }

    private func waitForProviderClose(_ owner: SSHPreparedConnectionSpy) async throws {
        try await HardOperationDeadline.run(timeout: .seconds(2)) {
            while !owner.didCloseAfterDescriptor {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private func makeSession(owner: SSHPreparedConnectionSpy, timeout: TimeInterval = 30) -> SSHSession {
        SSHSession(
            config: SSHSessionConfig(
                host: "provider.invalid",
                port: 3022,
                username: "test",
                connectionMode: .standard,
                authMethod: .password,
                credentials: ServerCredentials(serverId: UUID(), password: "must-not-be-used"),
                connectionTimeout: timeout
            ),
            hostKeyVerifier: TestingSSHHostKeyVerifier(),
            preparedConnection: owner
        )
    }

    private func makeSocketPair() throws -> (client: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SSHError.connectionFailed("Cannot create the local test stream")
        }
        return (descriptors[0], descriptors[1])
    }
}
