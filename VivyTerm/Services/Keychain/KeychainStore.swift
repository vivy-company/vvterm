//
//  KeychainStore.swift
//  VivyTerm
//
//  Keychain wrapper for storing credentials with optional iCloud sync
//

import Foundation
import Security

final class KeychainStore: @unchecked Sendable {
    private let service: String

    init(service: String) {
        self.service = service
    }

    // MARK: - Data Operations

    nonisolated func set(_ data: Data, forKey key: String, iCloudSync: Bool = false) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Remove existing item if any
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = iCloudSync
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        if iCloudSync {
            attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    nonisolated func get(_ key: String) throws -> Data? {
        // First try with iCloud sync (kSecAttrSynchronizable = true)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Search both synced and non-synced
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }

        return item as? Data
    }

    nonisolated func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Delete both synced and non-synced
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    // MARK: - String Convenience

    nonisolated func setString(_ value: String, forKey key: String, iCloudSync: Bool = false) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try set(data, forKey: key, iCloudSync: iCloudSync)
    }

    nonisolated func getString(_ key: String) throws -> String? {
        guard let data = try get(key) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }
}

// MARK: - Keychain Error

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case encodingFailed
    case decodingFailed
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode data for keychain"
        case .decodingFailed:
            return "Failed to decode data from keychain"
        case .itemNotFound:
            return "Item not found in keychain"
        }
    }
}
