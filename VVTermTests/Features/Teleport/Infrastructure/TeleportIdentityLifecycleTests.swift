#if os(macOS)
import Foundation
import TeleportKit
import Testing
@testable import VVTerm

private nonisolated final class PausedTeleportKeychainRead: KeychainStoreBacking, @unchecked Sendable {
    private enum ReadState { case idle, armed, blocked }
    private let backing = InMemoryKeychainStoreBacking()
    private let lock = NSLock()
    private let resumeRead = DispatchSemaphore(value: 0)
    private var readState = ReadState.idle

    var isBlocked: Bool { lock.withLock { if case .blocked = readState { true } else { false } } }
    func pauseNextRead() { lock.withLock { readState = .armed } }
    func releaseRead() {
        let shouldResume = lock.withLock {
            let wasBlocked: Bool
            if case .blocked = readState { wasBlocked = true } else { wasBlocked = false }
            readState = .idle
            return wasBlocked
        }
        if shouldResume { resumeRead.signal() }
    }

    func get(service: String, key: String, scope: KeychainStorageScope) throws -> Data? {
        let snapshot = try backing.get(service: service, key: key, scope: scope)
        let shouldPause = lock.withLock {
            guard case .armed = readState else { return false }
            readState = .blocked
            return true
        }
        if shouldPause { _ = resumeRead.wait(timeout: .now() + 5) }
        return snapshot
    }
    func set(_ data: Data, service: String, key: String, scope: KeychainStorageScope) throws {
        try backing.set(data, service: service, key: key, scope: scope)
    }
    func contains(service: String, key: String, scope: KeychainStorageScope) throws -> Bool {
        try backing.contains(service: service, key: key, scope: scope)
    }
    func delete(service: String, key: String, scope: KeychainStorageScope) throws {
        try backing.delete(service: service, key: key, scope: scope)
    }
    func keys(service: String, scope: KeychainStorageScope) throws -> [String] {
        try backing.keys(service: service, scope: scope)
    }
}

@MainActor
struct TeleportIdentityLifecycleTests {
    @Test
    func signOutRejectsAnEarlierSummaryAfterItsRecordReadFinishes() async throws {
        let fixture = try await Task.detached { try TeleportIdentityFixture() }.value
        let profile = try TeleportProfileConfiguration(proxyURL: fixture.identity.proxy.url.absoluteString, account: "alice")
        let backing = PausedTeleportKeychainRead()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        try await TeleportKeychainIdentityStore(keychain: keychain, profileID: profile.identifier)
            .replace(with: fixture.identity)
        let service = TeleportAccessService(
            keychain: keychain,
            makeBrowserSession: { _, _ in UnusedTeleportLifecycleBrowser() },
            didSignOut: { _ in }
        )
        backing.pauseNextRead()
        let summary = Task { try await service.summary(for: profile) }
        defer { backing.releaseRead(); summary.cancel() }
        try await HardOperationDeadline.run(timeout: .seconds(2)) {
            while !backing.isBlocked { try await Task.sleep(for: .milliseconds(1)) }
        }

        try await service.signOut(profile: profile)
        backing.releaseRead()

        #expect(try await summary.value == nil)
        #expect(try keychain.get(profile.identifier, scope: .deviceOnly) == nil)
    }

    @Test
    func validIdentityIsBoundToItsExactProxyAndAccountOnReadAndWrite() async throws {
        let fixture = try await Task.detached { try TeleportIdentityFixture() }.value
        let correct = try TeleportProfileConfiguration(proxyURL: fixture.identity.proxy.url.absoluteString, account: "alice")
        let wrongProfiles = [
            try TeleportProfileConfiguration(proxyURL: fixture.identity.proxy.url.absoluteString, account: "bob"),
            try TeleportProfileConfiguration(proxyURL: "https://other-proxy.example.test", account: "alice"),
        ]
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        let store = TeleportKeychainIdentityStore(keychain: keychain, profileID: correct.identifier)
        try await store.replace(with: fixture.identity)
        #expect(try await store.load()?.username == "alice")
        let bytes = try #require(try keychain.get(correct.identifier, scope: .deviceOnly))
        for wrong in wrongProfiles {
            try keychain.set(bytes, forKey: wrong.identifier, scope: .deviceOnly)
            let wrongStore = TeleportKeychainIdentityStore(keychain: keychain, profileID: wrong.identifier)
            let before = backing.snapshot()
            do {
                _ = try await wrongStore.load()
                Issue.record("A valid identity under the wrong profile key must be rejected")
            } catch TeleportError.invalidCertificate {}
            do {
                try await wrongStore.replace(with: fixture.identity)
                Issue.record("An identity must not be written to another profile")
            } catch TeleportError.invalidCertificate {}
            #expect(backing.snapshot() == before)
        }
    }

    @Test
    func failedWholeIdentityWritePreservesThePreviousRecord() async throws {
        let fixture = try await Task.detached { try TeleportIdentityFixture() }.value
        let profile = try TeleportProfileConfiguration(proxyURL: fixture.identity.proxy.url.absoluteString, account: "alice")
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        let previous = Data("previous durable record".utf8)
        try keychain.set(previous, forKey: profile.identifier, scope: .deviceOnly)
        backing.failWrites(to: .deviceOnly, service: keychain.service, key: profile.identifier)

        do {
            try await TeleportKeychainIdentityStore(keychain: keychain, profileID: profile.identifier)
                .replace(with: fixture.identity)
            Issue.record("A failed whole-record update must be reported")
        } catch InMemoryKeychainStoreBacking.Failure.writeRejected {}
        #expect(try keychain.get(profile.identifier, scope: .deviceOnly) == previous)
    }
}

@MainActor
private final class UnusedTeleportLifecycleBrowser: TeleportBrowserSession {
    func open(_ url: URL) async throws { throw TeleportError.invalidConfiguration("unexpected browser") }
    func cancel() {}
}
#endif
