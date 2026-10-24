import Foundation
import TeleportKit

/// One atomic, device-only record per proxy/account. Server deletion does not own it.
actor TeleportKeychainIdentityStore: TeleportIdentityStore {
    private let keychain: KeychainStore
    private let profileID: String
    private let recordLimit = 1_048_576

    init(keychain: KeychainStore, profileID: String) {
        self.keychain = keychain
        self.profileID = profileID
    }

    func load() throws -> TeleportIdentity? {
        guard let data = try keychain.get(profileID, scope: .deviceOnly) else { return nil }
        guard data.count <= recordLimit else { throw TeleportError.limitExceeded("identity record") }
        let identity = try JSONDecoder().decode(TeleportIdentity.self, from: data)
        try validateBinding(identity)
        return identity
    }

    func replace(with identity: TeleportIdentity?) throws {
        guard let identity else {
            try keychain.delete(profileID, scope: .deviceOnly)
            return
        }
        try validateBinding(identity)
        let data = try JSONEncoder().encode(identity)
        guard data.count <= recordLimit else { throw TeleportError.limitExceeded("identity record") }
        try keychain.set(data, forKey: profileID, scope: .deviceOnly)
    }

    private func validateBinding(_ identity: TeleportIdentity) throws {
        let profile = try TeleportProfileConfiguration(
            proxyURL: identity.proxy.url.absoluteString,
            account: identity.username
        )
        guard profile.identifier == profileID else {
            throw TeleportError.invalidCertificate("account profile")
        }
    }
}
