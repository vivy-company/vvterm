//
//  KeychainStore.swift
//  VVTerm
//
//  Explicit device-only and iCloud Keychain storage.
//

import Foundation
import Security

nonisolated enum KeychainStorageScope: String, CaseIterable, Codable, Hashable, Sendable {
    case deviceOnly
    case iCloud

    var isSynchronizable: Bool {
        self == .iCloud
    }

    var accessibility: CFString {
        switch self {
        case .deviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .iCloud:
            kSecAttrAccessibleAfterFirstUnlock
        }
    }

    var alternate: Self {
        switch self {
        case .deviceOnly: .iCloud
        case .iCloud: .deviceOnly
        }
    }
}

nonisolated protocol KeychainStoreBacking: Sendable {
    func set(
        _ data: Data,
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws
    func get(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Data?
    func contains(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Bool
    func delete(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws
    func keys(
        service: String,
        scope: KeychainStorageScope
    ) throws -> [String]
}

nonisolated final class SecurityKeychainStoreBacking: KeychainStoreBacking, @unchecked Sendable {
    func set(
        _ data: Data,
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws {
        let query = itemQuery(service: service, key: key, scope: scope)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: scope.accessibility
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = scope.accessibility
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(addStatus)
        }
    }

    func get(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Data? {
        var query = itemQuery(service: service, key: key, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        return item as? Data
    }

    func contains(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Bool {
        var query = itemQuery(service: service, key: key, scope: scope)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status != errSecItemNotFound else { return false }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        return true
    }

    func delete(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws {
        let status = SecItemDelete(
            itemQuery(service: service, key: key, scope: scope) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    func keys(
        service: String,
        scope: KeychainStorageScope
    ) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: scope.isSynchronizable,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }

        let attributes: [[String: Any]]
        if let values = result as? [[String: Any]] {
            attributes = values
        } else if let value = result as? [String: Any] {
            attributes = [value]
        } else {
            return []
        }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func itemQuery(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: scope.isSynchronizable
        ]
    }
}

nonisolated final class KeychainStore: @unchecked Sendable {
    let service: String
    private let backing: any KeychainStoreBacking

    init(
        service: String,
        backing: any KeychainStoreBacking = SecurityKeychainStoreBacking()
    ) {
        self.service = service
        self.backing = backing
    }

    func set(
        _ data: Data,
        forKey key: String,
        scope: KeychainStorageScope
    ) throws {
        try backing.set(data, service: service, key: key, scope: scope)
    }

    func get(
        _ key: String,
        scope: KeychainStorageScope
    ) throws -> Data? {
        try backing.get(service: service, key: key, scope: scope)
    }

    func contains(
        _ key: String,
        scope: KeychainStorageScope
    ) throws -> Bool {
        try backing.contains(service: service, key: key, scope: scope)
    }

    func delete(
        _ key: String,
        scope: KeychainStorageScope
    ) throws {
        try backing.delete(service: service, key: key, scope: scope)
    }

    func copyAll(
        from source: KeychainStorageScope,
        to destination: KeychainStorageScope,
        where shouldCopy: (String) -> Bool
    ) throws {
        guard source != destination else { return }
        let keys = try matchingKeys(in: source, where: shouldCopy)
        for key in keys {
            try copy(key, from: source, to: destination)
        }
    }

    func moveAll(
        from source: KeychainStorageScope,
        to destination: KeychainStorageScope,
        where shouldMove: (String) -> Bool
    ) throws {
        guard source != destination else { return }
        let keys = try matchingKeys(in: source, where: shouldMove)
        for key in keys {
            try copy(key, from: source, to: destination)
        }
        for key in keys {
            try delete(key, scope: source)
        }
    }

    func deleteAll(
        in scope: KeychainStorageScope,
        where shouldDelete: (String) -> Bool
    ) throws {
        for key in try matchingKeys(in: scope, where: shouldDelete) {
            try delete(key, scope: scope)
        }
    }

    func keys(in scope: KeychainStorageScope) throws -> [String] {
        try backing.keys(service: service, scope: scope).sorted()
    }

    private func matchingKeys(
        in scope: KeychainStorageScope,
        where predicate: (String) -> Bool
    ) throws -> [String] {
        try backing.keys(service: service, scope: scope)
            .filter(predicate)
            .sorted()
    }

    @discardableResult
    private func copy(
        _ key: String,
        from source: KeychainStorageScope,
        to destination: KeychainStorageScope
    ) throws -> Bool {
        guard let sourceData = try get(key, scope: source) else { return false }
        try set(sourceData, forKey: key, scope: destination)
        guard try get(key, scope: destination) == sourceData else {
            throw KeychainError.copyVerificationFailed
        }
        return true
    }

    func setString(
        _ value: String,
        forKey key: String,
        scope: KeychainStorageScope
    ) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try set(data, forKey: key, scope: scope)
    }

    func getString(
        _ key: String,
        scope: KeychainStorageScope
    ) throws -> String? {
        guard let data = try get(key, scope: scope) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }
}

nonisolated enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case encodingFailed
    case decodingFailed
    case itemNotFound
    case credentialServerMismatch
    case copyVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            "Keychain error: \(status)"
        case .encodingFailed:
            "Failed to encode data for Keychain"
        case .decodingFailed:
            "Failed to decode data from Keychain"
        case .itemNotFound:
            "Item not found in Keychain"
        case .credentialServerMismatch:
            "Credentials do not belong to this server"
        case .copyVerificationFailed:
            "VVTerm could not verify the copied Keychain item"
        }
    }
}
