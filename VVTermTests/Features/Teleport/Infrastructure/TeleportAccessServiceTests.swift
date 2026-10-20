import Foundation
import Security
import TeleportKit
import Testing
@testable import VVTerm

@MainActor
private final class UnusedTeleportBrowserSession: TeleportBrowserSession {
    func open(_ url: URL) async throws { throw TeleportError.invalidConfiguration("unexpected browser") }
    func cancel() {}
}

@MainActor
private final class TeleportSignOutRecorder {
    var profileIDs: [String] = []
}

@MainActor
struct TeleportAccessServiceTests {
    @Test
    func missingIdentityFailsBeforeAnyNodeConnection() async throws {
        let keychain = KeychainStore(service: "test.teleport", backing: InMemoryKeychainStoreBacking())
        let service = makeService(keychain: keychain)
        do {
            _ = try await service.prepare(.init(profileID: "absent", clusterName: "root", nodeID: "node", login: "alice"))
            Issue.record("An absent identity must require sign-in")
        } catch SSHError.connectionFailed(let message) {
            #expect(message == TeleportAccessError.message(for: TeleportError.authenticationRequired))
        }
    }

    @Test
    func summaryPropagatesStorageFailure() async throws {
        let keychain = KeychainStore(service: "test.teleport", backing: UnavailableTeleportKeychainBacking())
        let service = makeService(keychain: keychain)
        do {
            _ = try await service.summary(for: makeProfile())
            Issue.record("A storage failure must not appear as a signed-out profile")
        } catch KeychainError.unhandled(let status) {
            #expect(status == errSecNotAvailable)
        }
    }

    @Test
    func failedSignOutCanBeRetriedAndAffectsOnlyThatProfile() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        let recorder = TeleportSignOutRecorder()
        let service = makeService(keychain: keychain, recorder: recorder)
        let profile = try makeProfile()
        let value = Data("record to delete without decoding".utf8)
        try keychain.set(value, forKey: profile.identifier, scope: .deviceOnly)
        try keychain.set(value, forKey: "other-profile", scope: .deviceOnly)
        try keychain.set(value, forKey: profile.identifier, scope: .iCloud)
        backing.failDeletes(from: .deviceOnly, service: keychain.service, key: profile.identifier)

        do {
            try await service.signOut(profile: profile)
            Issue.record("A failed credential delete must fail sign-out")
        } catch InMemoryKeychainStoreBacking.Failure.deleteRejected {}
        #expect(try keychain.get(profile.identifier, scope: .deviceOnly) == value)
        backing.allowDeletes(from: .deviceOnly, service: keychain.service, key: profile.identifier)

        try await service.signOut(profile: profile)

        #expect(recorder.profileIDs == [profile.identifier, profile.identifier])
        #expect(try keychain.get(profile.identifier, scope: .deviceOnly) == nil)
        #expect(try keychain.get(profile.identifier, scope: .iCloud) == value)
        #expect(try keychain.get("other-profile", scope: .deviceOnly) == value)
        #expect(try await service.summary(for: profile) == nil)
    }

    private func makeProfile() throws -> TeleportProfileConfiguration {
        try TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice")
    }

    private func makeService(keychain: KeychainStore, recorder: TeleportSignOutRecorder? = nil) -> TeleportAccessService {
        TeleportAccessService(
            keychain: keychain,
            makeBrowserSession: { _, _ in UnusedTeleportBrowserSession() },
            didSignOut: { recorder?.profileIDs.append($0) }
        )
    }
}
