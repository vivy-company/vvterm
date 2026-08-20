import Testing
@testable import VVTerm

struct SSHConnectedSessionPolicyTests {
    @Test
    func liveMatchingConnectionIsReused() {
        #expect(
            SSHConnectedSessionPolicy.action(
                existingConnectionKey: "server-a",
                requestedConnectionKey: "server-a",
                transportIsConnected: true
            ) == .reuse
        )
    }

    @Test
    func liveDifferentConnectionIsRejected() {
        #expect(
            SSHConnectedSessionPolicy.action(
                existingConnectionKey: "server-a",
                requestedConnectionKey: "server-b",
                transportIsConnected: true
            ) == .reject
        )
    }

    @Test
    func deadConnectionIsRecoveredForEitherKey() {
        #expect(
            SSHConnectedSessionPolicy.action(
                existingConnectionKey: "server-a",
                requestedConnectionKey: "server-a",
                transportIsConnected: false
            ) == .recover
        )
        #expect(
            SSHConnectedSessionPolicy.action(
                existingConnectionKey: "server-a",
                requestedConnectionKey: "server-b",
                transportIsConnected: false
            ) == .recover
        )
    }
}
