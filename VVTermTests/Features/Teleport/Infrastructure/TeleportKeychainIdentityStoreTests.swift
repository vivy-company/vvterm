import Foundation
import Security
import TeleportKit
import Testing
@testable import VVTerm

nonisolated struct UnavailableTeleportKeychainBacking: KeychainStoreBacking {
    func set(_ data: Data, service: String, key: String, scope: KeychainStorageScope) throws {
        throw KeychainError.unhandled(errSecNotAvailable)
    }
    func get(service: String, key: String, scope: KeychainStorageScope) throws -> Data? {
        throw KeychainError.unhandled(errSecNotAvailable)
    }
    func contains(service: String, key: String, scope: KeychainStorageScope) throws -> Bool {
        throw KeychainError.unhandled(errSecNotAvailable)
    }
    func delete(service: String, key: String, scope: KeychainStorageScope) throws {
        throw KeychainError.unhandled(errSecNotAvailable)
    }
    func keys(service: String, scope: KeychainStorageScope) throws -> [String] {
        throw KeychainError.unhandled(errSecNotAvailable)
    }
}

struct TeleportKeychainIdentityStoreTests {
    @Test
    func oversizedRecordIsRejectedBeforeJSONDecodeAndIsPreserved() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        let bytes = Data(repeating: 0, count: 1_048_577)
        try keychain.set(bytes, forKey: "profile", scope: .deviceOnly)
        let store = TeleportKeychainIdentityStore(keychain: keychain, profileID: "profile")

        do {
            _ = try await store.load()
            Issue.record("An oversized record must be rejected")
        } catch TeleportError.limitExceeded(let field) {
            #expect(field == "identity record")
        }
        #expect(try keychain.get("profile", scope: .deviceOnly) == bytes)
    }

    @Test
    func synchronizedRecordCannotActAsADeviceIdentity() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        try keychain.set(Data("invalid synced record".utf8), forKey: "profile", scope: .iCloud)
        let before = backing.snapshot()
        let store = TeleportKeychainIdentityStore(keychain: keychain, profileID: "profile")

        #expect(try await store.load() == nil)
        #expect(backing.snapshot() == before)
    }

    @Test
    func nilReplacementDeletesOnlyTheSelectedDeviceRecord() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        for scope in KeychainStorageScope.allCases {
            try keychain.set(Data("profile".utf8), forKey: "profile", scope: scope)
            try keychain.set(Data("other".utf8), forKey: "other", scope: scope)
        }
        var expected = backing.snapshot()
        expected.removeValue(forKey: .init(service: keychain.service, key: "profile", scope: .deviceOnly))

        try await TeleportKeychainIdentityStore(keychain: keychain, profileID: "profile").replace(with: nil)

        #expect(backing.snapshot() == expected)
    }

    @Test
    func invalidJSONFailsWithoutDeletingTheRecord() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        let bytes = Data("invalid JSON".utf8)
        try keychain.set(bytes, forKey: "profile", scope: .deviceOnly)
        let store = TeleportKeychainIdentityStore(keychain: keychain, profileID: "profile")

        do {
            _ = try await store.load()
            Issue.record("Invalid stored data must not be treated as a signed-out profile")
        } catch is DecodingError {}
        #expect(try keychain.get("profile", scope: .deviceOnly) == bytes)
    }

    @Test
    func failedDeletionPreservesTheExistingRecordAndPropagatesTheError() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let keychain = KeychainStore(service: "test.teleport", backing: backing)
        let bytes = Data("existing".utf8)
        try keychain.set(bytes, forKey: "profile", scope: .deviceOnly)
        backing.failDeletes(from: .deviceOnly, service: keychain.service, key: "profile")

        do {
            try await TeleportKeychainIdentityStore(keychain: keychain, profileID: "profile").replace(with: nil)
            Issue.record("A failed Keychain delete must be reported")
        } catch InMemoryKeychainStoreBacking.Failure.deleteRejected {}
        #expect(try keychain.get("profile", scope: .deviceOnly) == bytes)
    }

    @Test
    func unavailableKeychainDoesNotLookLikeAnAbsentIdentity() async throws {
        let keychain = KeychainStore(service: "test.teleport", backing: UnavailableTeleportKeychainBacking())
        let store = TeleportKeychainIdentityStore(keychain: keychain, profileID: "profile")
        do {
            _ = try await store.load()
            Issue.record("Keychain access errors must be reported")
        } catch KeychainError.unhandled(let status) {
            #expect(status == errSecNotAvailable)
        }
    }
}
