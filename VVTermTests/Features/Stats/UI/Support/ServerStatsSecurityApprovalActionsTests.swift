import XCTest
@testable import VVTerm

final class ServerStatsSecurityApprovalActionsTests: XCTestCase {
    @MainActor
    func testApproveForwardsOnlyTheRequestToInjectedEffect() async {
        let server = makeServer()
        let request = makeHostKeyRequest(server: server)
        var receivedRequest: ServerSecurityApprovalRequest?
        let actions = ServerStatsSecurityApprovalActions(
            approve: { request in
                receivedRequest = request
                return .approved
            },
            reject: { _ in }
        )

        let outcome = await actions.approve(request)

        XCTAssertEqual(outcome, .approved)
        XCTAssertEqual(receivedRequest, request)
    }

    @MainActor
    func testRejectUsesOnlyItsInjectedEffect() {
        let request = makeHostKeyRequest(server: makeServer())
        var firstRejections: [ServerSecurityApprovalRequest] = []
        var secondRejections: [ServerSecurityApprovalRequest] = []
        let first = ServerStatsSecurityApprovalActions(
            approve: { _ in .approved },
            reject: { firstRejections.append($0) }
        )
        let second = ServerStatsSecurityApprovalActions(
            approve: { _ in .failed(.unavailable) },
            reject: { secondRejections.append($0) }
        )

        first.reject(request)

        XCTAssertEqual(firstRejections, [request])
        XCTAssertTrue(secondRejections.isEmpty)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "stats-actions-test",
            host: "stats.example.test",
            username: "tester"
        )
    }

    private func makeHostKeyRequest(server: Server) -> ServerSecurityApprovalRequest {
        .hostKey(
            KnownHostsManager.Challenge(
                id: UUID(),
                host: server.host,
                port: server.port,
                fingerprint: "SHA256:test",
                keyType: 1,
                keyTypeName: "ssh-ed25519",
                kind: .firstUse,
                createdAt: .distantPast
            )
        )
    }
}
