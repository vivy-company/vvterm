import Foundation
import Testing
@testable import VVTerm

struct SSHChannelCleanupTests {
    @Test
    func nonblockingChannelCleanupRetriesUntilComplete() async {
        let session = SSHSession(
            config: SSHSessionConfig(
                host: "test.invalid",
                port: 22,
                username: "test",
                connectionMode: .standard,
                authMethod: .password,
                credentials: ServerCredentials(serverId: UUID())
            ),
            hostKeyVerifier: TestingSSHHostKeyVerifier()
        )

        let result = await session.completeChannelCleanupCallForTesting(
            results: [
                Int32(LIBSSH2_ERROR_EAGAIN),
                Int32(LIBSSH2_ERROR_EAGAIN),
                0,
            ]
        )

        #expect(result.result == 0)
        #expect(result.callCount == 3)
    }
}
