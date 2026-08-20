import Foundation
import Cloudflared

actor CloudflareTokenStoreAdapter: TokenStore {
    private let store: KeychainStore
    private let isSyncEnabled: @Sendable () -> Bool
    private let offlineChanges: CredentialOfflineChangeStore
    private let offlineWrites: CredentialOfflineWriteTransaction

    init(
        store: KeychainStore = KeychainStore(
            service: KeychainManager.cloudflareTokenService
        ),
        isSyncEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled },
        offlineChanges: CredentialOfflineChangeStore = .shared
    ) {
        self.store = store
        self.isSyncEnabled = isSyncEnabled
        self.offlineChanges = offlineChanges
        offlineWrites = CredentialOfflineWriteTransaction(
            store: store,
            offlineChanges: offlineChanges
        )
    }

    func readToken(for key: String) async throws -> String? {
        try offlineWrites.resumePendingWrite()
        let key = namespacedKey(for: key)
        let preferredScope = storageScope
        if let token = try store.getString(key, scope: preferredScope) {
            return token
        }
        guard preferredScope == .iCloud else { return nil }
        return try store.getString(key, scope: .deviceOnly)
    }

    func writeToken(_ token: String, for key: String) async throws {
        let namespacedKey = namespacedKey(for: key)
        if isSyncEnabled() {
            try offlineWrites.resumePendingWrite()
            try store.setString(token, forKey: namespacedKey, scope: .iCloud)
        } else {
            guard let data = token.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            try offlineWrites.commitUpdate(
                for: .oauth(namespacedKey),
                operations: [.init(targetKey: namespacedKey, value: data)]
            )
        }
    }

    func removeToken(for key: String) async throws {
        try offlineWrites.resumePendingWrite()
        let namespacedKey = namespacedKey(for: key)
        if !isSyncEnabled() {
            try offlineChanges.record(.deleted, for: .oauth(namespacedKey))
        }
        for scope in KeychainStorageScope.allCases {
            try store.delete(namespacedKey, scope: scope)
        }
    }

    private var storageScope: KeychainStorageScope {
        isSyncEnabled() ? .iCloud : .deviceOnly
    }

    private func namespacedKey(for key: String) -> String {
        "oauth.\(key)"
    }
}
