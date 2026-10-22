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
    @Test(arguments: ["oidc", "saml", "github", "unknown"])
    func nonlocalAccountsAreRejected(authenticationType: String) {
        let discovery = TeleportDiscovery(
            clusterName: "root", serverVersion: "18.11.4", authenticationType: authenticationType,
            secondFactor: "off", connectors: [], webAuthnConfigured: true
        )
        #expect(throws: TeleportAccessError.localAccountsOnly) {
            try TeleportAccessService.requireLocalAccount(discovery)
        }
    }

    @Test
    func localAccountsDoNotRequireAnAppPasswordOrConnector() throws {
        try TeleportAccessService.requireLocalAccount(TeleportDiscovery(
            clusterName: "root", serverVersion: "18.11.4", authenticationType: "local",
            secondFactor: "webauthn", connectors: [], webAuthnConfigured: true
        ))
        let name = TeleportAccessService.deviceCredentialName()
        #expect(name.hasPrefix("VVTerm-"))
        #expect(name.utf8.count <= 30)
    }

    @Test(arguments: [
        TeleportError.accessDenied, .biometricsUnavailable, .deviceCredentialStorage,
        .deviceCredentialExists, .unsupportedPolicy(.hardwareKey),
    ])
    func failedDeviceApprovalDoesNotStartBrowserSetup(error: TeleportError) async throws {
        let calls = TeleportAuthenticationCalls()
        do {
            _ = try await TeleportAccessService.authenticate(
                withDeviceKey: { throw error },
                registerDeviceKey: {
                    await calls.record("registration")
                    throw TeleportError.invalidResponse("unexpected registration")
                }
            )
            Issue.record("The native failure must reach the caller")
        } catch let actual as TeleportError {
            #expect(actual == error)
        }
        #expect(await calls.values == [])
    }

    @Test
    func cancellationDoesNotStartBrowserSetup() async throws {
        let calls = TeleportAuthenticationCalls()
        let task = Task {
            try await TeleportAccessService.authenticate(
                withDeviceKey: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw TeleportError.deviceCredentialMissing
                },
                registerDeviceKey: {
                    await calls.record("registration")
                    throw TeleportError.invalidResponse("unexpected registration")
                }
            )
        }
        do {
            _ = try await task.value
            Issue.record("Cancellation must stop setup")
        } catch is CancellationError {}
        #expect(await calls.values == [])
    }

    @Test
    func failedSetupIsReportedWithoutDeletingOrRetryingTheKey() async throws {
        let calls = TeleportAuthenticationCalls()
        do {
            _ = try await TeleportAccessService.authenticate(
                withDeviceKey: { throw TeleportError.deviceCredentialMissing },
                registerDeviceKey: {
                    await calls.record("registration")
                    throw TeleportError.deviceCredentialExists
                }
            )
            Issue.record("Setup failure must reach the caller")
        } catch TeleportError.deviceCredentialExists {}
        #expect(await calls.values == ["registration"])
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func nativeLoginOrMissingKeySetupReturnsTheCompleteIdentity(missingKey: Bool) async throws {
        let fixture = try await Task.detached { try TeleportIdentityFixture() }.value
        let calls = TeleportAuthenticationCalls()
        let result = try await TeleportAccessService.authenticate(
            withDeviceKey: {
                await calls.record("native")
                if missingKey { throw TeleportError.deviceCredentialMissing }
                return fixture.identity
            },
            registerDeviceKey: {
                await calls.record("registration")
                return fixture.identity
            }
        )
        #expect(result.username == fixture.identity.username)
        let returnedCertificate = result.sshCertificateOpenSSH == fixture.identity.sshCertificateOpenSSH
        #expect(returnedCertificate)
        #expect(await calls.values == (missingKey ? ["native", "registration"] : ["native"]))
    }
    #endif

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

private actor TeleportAuthenticationCalls {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
