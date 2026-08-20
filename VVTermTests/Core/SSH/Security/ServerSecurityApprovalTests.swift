import XCTest
@testable import VVTerm

final class ServerSecurityApprovalTests: XCTestCase {
    func testDetectsPendingHostKeyApproval() throws {
        let suiteName = "ServerSecurityApprovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownHosts = KnownHostsManager(
            defaults: defaults,
            storageKey: "known-hosts"
        )
        let server = makeServer()
        guard case .approvalRequired(let challenge) = knownHosts.evaluate(
            host: server.host,
            port: server.port,
            fingerprint: "SHA256:test",
            keyType: 1,
            keyTypeName: "ssh-ed25519"
        ) else {
            return XCTFail("Expected an approval challenge")
        }

        XCTAssertEqual(
            ServerSecurityApprovalRequest.detect(
                SSHError.hostKeyApprovalRequired,
                host: server.host,
                port: server.port,
                knownHosts: knownHosts
            ),
            .hostKey(challenge)
        )
    }

    func testDoesNotInventMissingOrExpiredHostKeyChallenge() throws {
        let suiteName = "ServerSecurityApprovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownHosts = KnownHostsManager(
            defaults: defaults,
            storageKey: "known-hosts"
        )

        let server = makeServer()
        XCTAssertNil(
            ServerSecurityApprovalRequest.detect(
                SSHError.hostKeyApprovalRequired,
                host: server.host,
                port: server.port,
                knownHosts: knownHosts
            )
        )
    }

    func testFirstUseHostKeyPresentationKeepsTrustCopyAndRole() {
        let challenge = makeChallenge(kind: .firstUse)
        let presentation = SSHHostKeyTrustPresentation(
            request: .hostKey(challenge)
        )
        let endpoint = "\(challenge.host):\(challenge.port)"
        let details = String(
            format: String(localized: "Host: %@\nKey type: %@\nFingerprint: %@"),
            endpoint,
            challenge.keyTypeName,
            challenge.fingerprint
        )

        XCTAssertEqual(presentation.title, String(localized: "Trust SSH Host?"))
        XCTAssertEqual(
            presentation.message,
            String(
                format: String(localized: "VVTerm has not seen this SSH host before. Verify this fingerprint through a trusted source before you continue.\n\n%@"),
                details
            )
        )
        XCTAssertEqual(
            presentation.approvalButtonTitle,
            String(localized: "Trust and Reconnect")
        )
        XCTAssertFalse(presentation.isDestructive)
    }

    func testChangedHostKeyPresentationKeepsReplacementCopyAndRole() {
        let previousFingerprint = "SHA256:previous"
        let challenge = makeChallenge(kind: .changed(previousFingerprint: previousFingerprint))
        let presentation = SSHHostKeyTrustPresentation(
            request: .hostKey(challenge)
        )
        let endpoint = "\(challenge.host):\(challenge.port)"
        let details = String(
            format: String(localized: "Host: %@\nKey type: %@\nFingerprint: %@"),
            endpoint,
            challenge.keyTypeName,
            challenge.fingerprint
        )

        XCTAssertEqual(presentation.title, String(localized: "Replace Trusted Host?"))
        XCTAssertEqual(
            presentation.message,
            String(
                format: String(localized: "The SSH host key changed. Only continue if you recreated this server or verified the new key.\n\nPrevious: %@\n%@"),
                previousFingerprint,
                details
            )
        )
        XCTAssertEqual(
            presentation.approvalButtonTitle,
            String(localized: "Replace and Reconnect")
        )
        XCTAssertTrue(presentation.isDestructive)
    }

    private func makeChallenge(
        kind: KnownHostsManager.Challenge.Kind
    ) -> KnownHostsManager.Challenge {
        KnownHostsManager.Challenge(
            id: UUID(),
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:test",
            keyType: 1,
            keyTypeName: "ssh-ed25519",
            kind: kind,
            createdAt: .distantPast
        )
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 22,
            username: "root",
            authMethod: .password
        )
    }
}
