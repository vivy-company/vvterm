import Foundation
import Cloudflared

actor CloudflareTokenStoreAdapter: TokenStore {
    private let store = KeychainStore(service: "app.vivy.vvterm.cloudflare.tokens")

    func readToken(for key: String) async throws -> String? {
        try store.getString(namespacedKey(for: key))
    }

    func writeToken(_ token: String, for key: String) async throws {
        try store.setString(
            token,
            forKey: namespacedKey(for: key),
            iCloudSync: SyncSettings.isEnabled
        )
    }

    func removeToken(for key: String) async throws {
        try store.delete(namespacedKey(for: key))
    }

    private func namespacedKey(for key: String) -> String {
        "oauth.\(key)"
    }
}
