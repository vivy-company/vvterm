import Foundation
import Security
import XCTest
@testable import VVTerm

final class KeychainStoreTests: XCTestCase {
    private var service = ""
    private var key = ""
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        service = "app.vivy.vvterm.tests.\(UUID().uuidString)"
        key = UUID().uuidString
        store = KeychainStore(service: service)
    }

    override func tearDown() {
        for scope in KeychainStorageScope.allCases {
            try? store.delete(key, scope: scope)
        }
        store = nil
        super.tearDown()
    }

    func testSetStoresDeviceOnlyItem() throws {
        let expected = Data("local-secret".utf8)

        try store.set(expected, forKey: key, scope: .deviceOnly)

        XCTAssertEqual(try store.get(key, scope: .deviceOnly), expected)
        XCTAssertNil(try store.get(key, scope: .iCloud))
    }

    func testSetStoresSynchronizedItem() throws {
        let expected = Data("cloud-secret".utf8)

        do {
            try store.set(expected, forKey: key, scope: .iCloud)
        } catch KeychainError.unhandled(let status)
            where status == errSecMissingEntitlement || status == errSecNotAvailable {
            throw XCTSkip("Synchronized Keychain items are unavailable in this test environment")
        }

        XCTAssertEqual(try store.get(key, scope: .iCloud), expected)
        XCTAssertNil(try store.get(key, scope: .deviceOnly))
    }

    func testGetDoesNotDeleteEitherCopy() throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(service: service, backing: backing)
        try store.set(Data("local".utf8), forKey: key, scope: .deviceOnly)
        try store.set(Data("cloud".utf8), forKey: key, scope: .iCloud)
        let before = backing.snapshot()

        XCTAssertEqual(
            try store.get(key, scope: .deviceOnly),
            Data("local".utf8)
        )
        XCTAssertEqual(
            try store.get(key, scope: .iCloud),
            Data("cloud".utf8)
        )
        XCTAssertEqual(backing.snapshot(), before)
    }

    func testContainsDoesNotModifyStorage() throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(service: service, backing: backing)
        try store.set(Data("local".utf8), forKey: key, scope: .deviceOnly)
        try store.set(Data("cloud".utf8), forKey: key, scope: .iCloud)
        let before = backing.snapshot()

        XCTAssertTrue(try store.contains(key, scope: .deviceOnly))
        XCTAssertTrue(try store.contains(key, scope: .iCloud))
        XCTAssertEqual(backing.snapshot(), before)
    }

    func testCopyWritesAndVerifiesDestinationWithoutDeletingSource() throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(service: service, backing: backing)
        let expected = Data("local".utf8)
        try store.set(expected, forKey: key, scope: .deviceOnly)

        try store.copyAll(
            from: .deviceOnly,
            to: .iCloud,
            where: { $0 == self.key }
        )

        XCTAssertEqual(try store.get(key, scope: .deviceOnly), expected)
        XCTAssertEqual(try store.get(key, scope: .iCloud), expected)
    }

    func testFailedDestinationWritePreservesSource() throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(service: service, backing: backing)
        let expected = Data("local".utf8)
        try store.set(expected, forKey: key, scope: .deviceOnly)
        backing.failWrites(to: .iCloud)

        XCTAssertThrowsError(
            try store.copyAll(
                from: .deviceOnly,
                to: .iCloud,
                where: { $0 == self.key }
            )
        )
        XCTAssertEqual(try store.get(key, scope: .deviceOnly), expected)
        XCTAssertNil(try store.get(key, scope: .iCloud))
    }

    func testFailedDestinationVerificationPreservesSource() throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(service: service, backing: backing)
        let expected = Data("local".utf8)
        try store.set(expected, forKey: key, scope: .deviceOnly)
        backing.corruptReads(from: .iCloud, service: service, key: key)

        XCTAssertThrowsError(
            try store.copyAll(
                from: .deviceOnly,
                to: .iCloud,
                where: { $0 == self.key }
            )
        ) { error in
            guard case KeychainError.copyVerificationFailed = error else {
                XCTFail("Expected copy verification failure, got \(error)")
                return
            }
        }
        XCTAssertEqual(try store.get(key, scope: .deviceOnly), expected)
    }

    func testMoveDoesNotDeleteAnySourceUntilEveryCopySucceeds() throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(service: service, backing: backing)
        let firstKey = "a"
        let secondKey = "b"
        try store.set(Data("first".utf8), forKey: firstKey, scope: .deviceOnly)
        try store.set(Data("second".utf8), forKey: secondKey, scope: .deviceOnly)
        backing.failWrites(to: .iCloud, service: service, key: secondKey)

        XCTAssertThrowsError(
            try store.moveAll(
                from: .deviceOnly,
                to: .iCloud,
                where: { $0 == firstKey || $0 == secondKey }
            )
        )

        XCTAssertEqual(try store.get(firstKey, scope: .deviceOnly), Data("first".utf8))
        XCTAssertEqual(try store.get(secondKey, scope: .deviceOnly), Data("second".utf8))
        XCTAssertEqual(try store.get(firstKey, scope: .iCloud), Data("first".utf8))
        XCTAssertNil(try store.get(secondKey, scope: .iCloud))
    }
}

nonisolated final class InMemoryKeychainStoreBacking: KeychainStoreBacking, @unchecked Sendable {
    struct Item: Hashable {
        let service: String
        let key: String
        let scope: KeychainStorageScope
    }

    enum Failure: Error, Equatable {
        case writeRejected
        case deleteRejected
    }

    private let lock = NSLock()
    private var values: [Item: Data] = [:]
    private var failedWriteScopes: Set<KeychainStorageScope> = []
    private var failedWriteItems: Set<Item> = []
    private var failedDeleteItems: Set<Item> = []
    private var corruptedReadItems: Set<Item> = []

    func set(
        _ data: Data,
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let item = Item(service: service, key: key, scope: scope)
        guard !failedWriteScopes.contains(scope),
              !failedWriteItems.contains(item) else {
            throw Failure.writeRejected
        }
        values[item] = data
    }

    func get(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let item = Item(service: service, key: key, scope: scope)
        if corruptedReadItems.contains(item), values[item] != nil {
            return Data("corrupted".utf8)
        }
        return values[item]
    }

    func contains(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[Item(service: service, key: key, scope: scope)] != nil
    }

    func delete(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let item = Item(service: service, key: key, scope: scope)
        guard !failedDeleteItems.contains(item) else {
            throw Failure.deleteRejected
        }
        values.removeValue(forKey: item)
    }

    func keys(
        service: String,
        scope: KeychainStorageScope
    ) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.compactMap { item in
            item.service == service && item.scope == scope ? item.key : nil
        }
    }

    func failWrites(to scope: KeychainStorageScope) {
        lock.lock()
        failedWriteScopes.insert(scope)
        lock.unlock()
    }

    func failWrites(
        to scope: KeychainStorageScope,
        service: String,
        key: String
    ) {
        lock.lock()
        failedWriteItems.insert(Item(service: service, key: key, scope: scope))
        lock.unlock()
    }

    func allowWrites(
        to scope: KeychainStorageScope,
        service: String,
        key: String
    ) {
        lock.lock()
        failedWriteItems.remove(Item(service: service, key: key, scope: scope))
        lock.unlock()
    }

    func corruptReads(
        from scope: KeychainStorageScope,
        service: String,
        key: String
    ) {
        lock.lock()
        corruptedReadItems.insert(Item(service: service, key: key, scope: scope))
        lock.unlock()
    }

    func failDeletes(
        from scope: KeychainStorageScope,
        service: String,
        key: String
    ) {
        lock.lock()
        failedDeleteItems.insert(Item(service: service, key: key, scope: scope))
        lock.unlock()
    }

    func allowDeletes(
        from scope: KeychainStorageScope,
        service: String,
        key: String
    ) {
        lock.lock()
        failedDeleteItems.remove(Item(service: service, key: key, scope: scope))
        lock.unlock()
    }

    func snapshot() -> [Item: Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
