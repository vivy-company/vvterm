import Foundation
import Security
import os.log

// MARK: - Keychain Manager

@MainActor
final class KeychainManager {
    static let shared = KeychainManager()

    private let store: KeychainStore
    private let legacyStore: KeychainStore  // For migrating old credentials
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Keychain")

    private init() {
        store = KeychainStore(service: "app.vivy.VivyTerm")
        legacyStore = KeychainStore(service: "com.vivy.vivyterm")
    }

    // MARK: - Password Operations

    func storePassword(for serverId: UUID, password: String) throws {
        let key = passwordKey(for: serverId)
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try store.set(data, forKey: key, iCloudSync: true)
        logger.info("Stored password for server \(serverId.uuidString)")
    }

    func getPassword(for serverId: UUID) throws -> String? {
        let key = passwordKey(for: serverId)

        // Try new store first
        if let data = try store.get(key) {
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return password
        }

        // Fall back to legacy store for migration
        if let data = try legacyStore.get(key) {
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            // Migrate to new store
            try? store.set(data, forKey: key, iCloudSync: true)
            logger.info("Migrated password from legacy keychain")
            return password
        }

        return nil
    }

    // MARK: - SSH Key Operations

    func storeSSHKey(for serverId: UUID, privateKey: Data, passphrase: String?) throws {
        let keyKey = sshKeyKey(for: serverId)
        try store.set(privateKey, forKey: keyKey, iCloudSync: true)

        if let passphrase = passphrase {
            let passphraseKey = sshPassphraseKey(for: serverId)
            guard let passphraseData = passphrase.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            try store.set(passphraseData, forKey: passphraseKey, iCloudSync: true)
        }

        logger.info("Stored SSH key for server \(serverId.uuidString)")
    }

    func getSSHKey(for serverId: UUID) throws -> (key: Data, passphrase: String?)? {
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)

        // Try new store first
        if let keyData = try store.get(keyKey) {
            var passphrase: String? = nil
            if let passphraseData = try store.get(passphraseKey) {
                passphrase = String(data: passphraseData, encoding: .utf8)
            }
            return (key: keyData, passphrase: passphrase)
        }

        // Fall back to legacy store for migration
        if let keyData = try legacyStore.get(keyKey) {
            var passphrase: String? = nil
            if let passphraseData = try legacyStore.get(passphraseKey) {
                passphrase = String(data: passphraseData, encoding: .utf8)
                // Migrate passphrase
                try? store.set(passphraseData, forKey: passphraseKey, iCloudSync: true)
            }
            // Migrate key
            try? store.set(keyData, forKey: keyKey, iCloudSync: true)
            logger.info("Migrated SSH key from legacy keychain")
            return (key: keyData, passphrase: passphrase)
        }

        return nil
    }

    // MARK: - Full Credentials

    func getCredentials(for server: Server) throws -> ServerCredentials {
        var credentials = ServerCredentials(serverId: server.id)

        logger.info("Getting credentials for server \(server.id.uuidString), authMethod: \(String(describing: server.authMethod))")

        switch server.authMethod {
        case .password:
            credentials.password = try getPassword(for: server.id)
            logger.info("Password retrieved: \(credentials.password != nil)")
        case .sshKey:
            if let sshData = try getSSHKey(for: server.id) {
                credentials.privateKey = sshData.key
            }
        case .sshKeyWithPassphrase:
            if let sshData = try getSSHKey(for: server.id) {
                credentials.privateKey = sshData.key
                credentials.passphrase = sshData.passphrase
            }
        }

        return credentials
    }

    // MARK: - Delete Operations

    func deleteCredentials(for serverId: UUID) throws {
        let passwordKey = passwordKey(for: serverId)
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)

        try? store.delete(passwordKey)
        try? store.delete(keyKey)
        try? store.delete(passphraseKey)

        logger.info("Deleted credentials for server \(serverId.uuidString)")
    }

    // MARK: - iCloud Sync

    func enableiCloudSync(for serverId: UUID) throws {
        // Already enabled by default in store operations
        logger.info("iCloud sync enabled for server \(serverId.uuidString)")
    }

    // MARK: - Key Generation

    private func passwordKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).password"
    }

    private func sshKeyKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).sshkey"
    }

    private func sshPassphraseKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).passphrase"
    }

    // MARK: - Reusable SSH Keys (Keychain Library)

    private let sshKeysIndexKey = "vivyterm.sshkeys.index"

    /// Get all stored SSH key entries (metadata only, not the actual keys)
    func getStoredSSHKeys() -> [SSHKeyEntry] {
        guard let data = try? store.get(sshKeysIndexKey),
              let keys = try? JSONDecoder().decode([SSHKeyEntry].self, from: data) else {
            return []
        }
        return keys.sorted { $0.createdAt > $1.createdAt }
    }

    /// Save the SSH key index
    private func saveSSHKeysIndex(_ keys: [SSHKeyEntry]) throws {
        let data = try JSONEncoder().encode(keys)
        try store.set(data, forKey: sshKeysIndexKey, iCloudSync: false)
    }

    /// Store a new SSH key in the keychain library
    func storeSSHKeyEntry(
        name: String,
        privateKey: Data,
        passphrase: String?,
        keyType: SSHKeyType? = nil,
        publicKey: String? = nil
    ) throws -> SSHKeyEntry {
        let entry = SSHKeyEntry(
            name: name,
            hasPassphrase: passphrase != nil && !passphrase!.isEmpty,
            createdAt: Date(),
            keyType: keyType,
            publicKey: publicKey
        )

        // Store the actual key data
        try store.set(privateKey, forKey: storedKeyDataKey(for: entry.id), iCloudSync: true)

        // Store passphrase if provided
        if let passphrase = passphrase, !passphrase.isEmpty,
           let passphraseData = passphrase.data(using: .utf8) {
            try store.set(passphraseData, forKey: storedKeyPassphraseKey(for: entry.id), iCloudSync: true)
        }

        // Update index
        var keys = getStoredSSHKeys()
        keys.append(entry)
        try saveSSHKeysIndex(keys)

        logger.info("Stored SSH key '\(name)' in keychain library")
        return entry
    }

    /// Get the actual key data for a stored SSH key
    func getStoredSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)? {
        guard let keyData = try store.get(storedKeyDataKey(for: keyId)) else {
            return nil
        }

        var passphrase: String? = nil
        if let passphraseData = try store.get(storedKeyPassphraseKey(for: keyId)) {
            passphrase = String(data: passphraseData, encoding: .utf8)
        }

        return (key: keyData, passphrase: passphrase)
    }

    /// Delete a stored SSH key from the library
    func deleteStoredSSHKey(_ keyId: UUID) throws {
        // Delete key data
        try? store.delete(storedKeyDataKey(for: keyId))
        try? store.delete(storedKeyPassphraseKey(for: keyId))

        // Update index
        var keys = getStoredSSHKeys()
        keys.removeAll { $0.id == keyId }
        try saveSSHKeysIndex(keys)

        logger.info("Deleted SSH key \(keyId.uuidString) from keychain library")
    }

    /// Update a stored SSH key's name
    func updateStoredSSHKeyName(_ keyId: UUID, name: String) throws {
        var keys = getStoredSSHKeys()
        guard let index = keys.firstIndex(where: { $0.id == keyId }) else {
            throw KeychainError.itemNotFound
        }
        keys[index].name = name
        try saveSSHKeysIndex(keys)
        logger.info("Updated SSH key name to '\(name)'")
    }

    private func storedKeyDataKey(for keyId: UUID) -> String {
        "sshkey.\(keyId.uuidString).data"
    }

    private func storedKeyPassphraseKey(for keyId: UUID) -> String {
        "sshkey.\(keyId.uuidString).passphrase"
    }
}

// KeychainError is defined in KeychainStore.swift
// ServerCredentials is defined in Server.swift
