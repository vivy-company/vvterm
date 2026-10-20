import Darwin
import Foundation
import Testing
@testable import VVTerm

private extension SSHSession {
    func installNativeSessionForFileLifetimeTest(descriptor: Int32) throws -> UUID {
        try LibSSH2Runtime.ensureInitialized()
        guard let native = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.notConnected
        }
        libssh2Session = native
        socket = descriptor
        atomicSocket.install(descriptor)
        isActive = true
        return try beginNativeFileOperation()
    }
}

struct SSHNativeFileOperationLifetimeTests {
    @Test
    func disconnectKeepsNativeSessionAndSocketUntilTheLastFileOperationEnds() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }
        let session = makeSession()
        let first = try await session.installNativeSessionForFileLifetimeTest(descriptor: descriptors[0])
        let second = try await session.beginNativeFileOperation()

        await session.disconnect()

        #expect(await session.hasBeenCleaned == false)
        #expect(fcntl(descriptors[0], F_GETFD) >= 0)
        do {
            try await session.validateNativeFileOperation()
            Issue.record("Suspended file work must stop after disconnect")
        } catch SSHError.notConnected {}
        await session.finishNativeFileOperation(first)
        #expect(await session.hasBeenCleaned == false)
        #expect(fcntl(descriptors[0], F_GETFD) >= 0)

        await session.finishNativeFileOperation(second)

        #expect(await session.hasBeenCleaned)
        #expect(fcntl(descriptors[0], F_GETFD) == -1)
    }

    @Test
    func disconnectedSessionRejectsNewFileWorkWithoutNativeAccess() async throws {
        let session = makeSession()
        do {
            _ = try await session.beginNativeFileOperation()
            Issue.record("A disconnected session must reject new file work")
        } catch SSHError.notConnected {}
        #expect(await session.nativeFileOperationsInFlight.isEmpty)
    }

    private func makeSession() -> SSHSession {
        SSHSession(
            config: SSHSessionConfig(
                host: "local.test.invalid", port: 22, username: "test", connectionMode: .standard,
                authMethod: .password, credentials: ServerCredentials(serverId: UUID())
            ),
            hostKeyVerifier: TestingSSHHostKeyVerifier()
        )
    }
}
