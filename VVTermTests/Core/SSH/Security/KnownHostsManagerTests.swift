import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct KnownHostsManagerTests {
    @Test
    func removeDeletesOnlyRequestedHostAndPort() {
        let manager = makeManager()
        manager.save(entry: entry(host: "example.com", port: 22, fingerprint: "SHA256:first"))
        manager.save(entry: entry(host: "example.com", port: 2222, fingerprint: "SHA256:second"))

        manager.remove(host: "example.com", port: 22)

        #expect(manager.entry(for: "example.com", port: 22) == nil)
        #expect(manager.entry(for: "example.com", port: 2222)?.fingerprint == "SHA256:second")
    }

    @Test
    func unknownHostNeedsApprovalAndIsNotPersisted() {
        let manager = makeManager()

        let result = manager.evaluate(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 6,
            keyTypeName: "ED25519"
        )

        guard case .approvalRequired(let challenge) = result else {
            Issue.record("Expected an approval challenge")
            return
        }
        #expect(challenge.kind == .firstUse)
        #expect(manager.entry(for: "example.com", port: 22) == nil)
    }

    @Test
    func rejectingFirstUsePersistsNothing() {
        let manager = makeManager()
        let challenge = approvalChallenge(from: manager.evaluate(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 6,
            keyTypeName: "ED25519"
        ))

        manager.reject(challenge)

        #expect(manager.entry(for: "example.com", port: 22) == nil)
        #expect(manager.pendingChallenge(for: "example.com", port: 22) == nil)
    }

    @Test
    func approvingExactFirstUseChallengePersistsFingerprint() {
        let manager = makeManager()
        let challenge = approvalChallenge(from: manager.evaluate(
            host: " EXAMPLE.COM. ",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 6,
            keyTypeName: "ED25519"
        ))

        #expect(manager.approve(challenge))
        #expect(manager.entry(for: "example.com", port: 22)?.fingerprint == "SHA256:new")
        #expect(
            manager.evaluate(
                host: "example.com",
                port: 22,
                fingerprint: "SHA256:new",
                keyType: 6,
                keyTypeName: "ED25519"
            ) == .trusted
        )
    }

    @Test
    func changedKeyKeepsOldFingerprintUntilExactApproval() {
        let manager = makeManager()
        manager.save(entry: entry(host: "example.com", port: 22, fingerprint: "SHA256:old"))
        let challenge = approvalChallenge(from: manager.evaluate(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 6,
            keyTypeName: "ED25519"
        ))

        #expect(challenge.kind == .changed(previousFingerprint: "SHA256:old"))
        #expect(manager.entry(for: "example.com", port: 22)?.fingerprint == "SHA256:old")
        #expect(manager.approve(challenge))
        #expect(manager.entry(for: "example.com", port: 22)?.fingerprint == "SHA256:new")
    }

    @Test
    func expiredChallengeCannotBeApproved() {
        let manager = makeManager()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let challenge = approvalChallenge(from: manager.evaluate(
            host: "example.com",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 6,
            keyTypeName: "ED25519",
            now: createdAt
        ))

        #expect(!manager.approve(challenge, now: createdAt.addingTimeInterval(121)))
        #expect(manager.entry(for: "example.com", port: 22) == nil)
    }

    @Test
    func removeAllClearsSavedHostsAndPendingChallenges() {
        let manager = makeManager()
        manager.save(entry: entry(host: "host.local", port: 22, fingerprint: "SHA256:host"))
        _ = manager.evaluate(
            host: "new.local",
            port: 22,
            fingerprint: "SHA256:new",
            keyType: 1,
            keyTypeName: "RSA"
        )

        manager.removeAll()

        #expect(manager.entries().isEmpty)
        #expect(manager.pendingChallenge(for: "new.local", port: 22) == nil)
    }

    private func makeManager() -> KnownHostsManager {
        let suiteName = "VVTermTests.KnownHosts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return KnownHostsManager(defaults: defaults, storageKey: "known-hosts")
    }

    private func entry(host: String, port: Int, fingerprint: String) -> KnownHostsManager.Entry {
        KnownHostsManager.Entry(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: 1,
            addedAt: Date(),
            lastSeenAt: Date()
        )
    }

    private func approvalChallenge(
        from result: KnownHostsManager.VerificationResult
    ) -> KnownHostsManager.Challenge {
        guard case .approvalRequired(let challenge) = result else {
            Issue.record("Expected an approval challenge")
            return KnownHostsManager.Challenge(
                id: UUID(),
                host: "invalid",
                port: 22,
                fingerprint: "invalid",
                keyType: 0,
                keyTypeName: "Unknown",
                kind: .firstUse,
                createdAt: Date()
            )
        }
        return challenge
    }
}
