import Foundation
import os.log

// MARK: - Keychain Manager

@MainActor
final class KeychainManager {
    nonisolated static let credentialService = "app.vivy.vvterm"
    nonisolated static let cloudflareTokenService = "app.vivy.vvterm.cloudflare.tokens"
    nonisolated static let iCloudMigrationKey = "vvterm.keychain.iCloudMigration.v1"

    static let shared = KeychainManager(performsInitialMigration: true)

    private let store: KeychainStore
    private let cloudflareTokenStore: KeychainStore
    private let isSyncEnabled: @Sendable () -> Bool
    private let persistSyncEnabled: @Sendable (Bool) throws -> Void
    private let offlineChanges: CredentialOfflineChangeStore
    private let credentialOfflineWrites: CredentialOfflineWriteTransaction
    private let oauthOfflineWrites: CredentialOfflineWriteTransaction
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Keychain")

    private struct CredentialBundle: Codable, Equatable {
        let serverID: UUID
        let binding: ServerCredentialBinding
        let password: String?
        let privateKey: Data?
        let publicKey: Data?
        let passphrase: String?
        let cloudflareClientID: String?
        let cloudflareClientSecret: String?

        init(credentials: ServerCredentials, server: Server) {
            serverID = server.id
            binding = ServerCredentialBinding(server: server)
            password = credentials.password
            privateKey = credentials.privateKey
            publicKey = credentials.publicKey
            passphrase = credentials.passphrase
            cloudflareClientID = credentials.cloudflareClientID
            cloudflareClientSecret = credentials.cloudflareClientSecret
        }
    }

    private struct StagedServerCredentialTransaction: Codable {
        struct Previous: Codable {
            let bundle: CredentialBundle
            let scope: KeychainStorageScope
        }

        let previous: Previous?
        let replacement: CredentialBundle
        let replacementScope: KeychainStorageScope
    }

    init(
        store: KeychainStore = KeychainStore(service: credentialService),
        cloudflareTokenStore: KeychainStore = KeychainStore(
            service: cloudflareTokenService
        ),
        isSyncEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled },
        persistSyncEnabled: @escaping @Sendable (Bool) throws -> Void = {
            try SyncSettings.persistEnabled($0)
        },
        offlineChanges: CredentialOfflineChangeStore = .shared,
        performsInitialMigration: Bool = false
    ) {
        self.store = store
        self.cloudflareTokenStore = cloudflareTokenStore
        self.isSyncEnabled = isSyncEnabled
        self.persistSyncEnabled = persistSyncEnabled
        self.offlineChanges = offlineChanges
        credentialOfflineWrites = CredentialOfflineWriteTransaction(
            store: store,
            offlineChanges: offlineChanges
        )
        oauthOfflineWrites = CredentialOfflineWriteTransaction(
            store: cloudflareTokenStore,
            offlineChanges: offlineChanges
        )
        if performsInitialMigration,
           shouldResumeCredentialStorageOnLaunch {
            do {
                try resumeCredentialStorageOnLaunch()
                if isSyncEnabled(), !offlineChanges.isTrackingOfflineChanges {
                    UserDefaults.standard.set(true, forKey: Self.iCloudMigrationKey)
                }
            } catch {
                logger.error("Could not prepare credential sync: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Password Operations

    private func storePassword(
        for serverId: UUID,
        password: String,
        scope: KeychainStorageScope
    ) throws {
        let key = passwordKey(for: serverId)
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try store.set(data, forKey: key, scope: scope)
        logger.info("Stored password for server \(serverId.uuidString)")
    }

    private func getPassword(
        for serverId: UUID,
        scope: KeychainStorageScope
    ) throws -> String? {
        let key = passwordKey(for: serverId)

        // Try store first
        if let data = try store.get(key, scope: scope) {
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return password
        }

        return nil
    }

    // MARK: - SSH Key Operations

    private func storeSSHKey(
        for serverId: UUID,
        privateKey: Data,
        passphrase: String?,
        publicKey: Data? = nil,
        scope: KeychainStorageScope
    ) throws {
        let keyKey = sshKeyKey(for: serverId)
        try store.set(privateKey, forKey: keyKey, scope: scope)

        if let passphrase = passphrase {
            let passphraseKey = sshPassphraseKey(for: serverId)
            guard let passphraseData = passphrase.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            try store.set(passphraseData, forKey: passphraseKey, scope: scope)
        }

        let publicKeyKey = sshPublicKeyKey(for: serverId)
        if let publicKey, !publicKey.isEmpty {
            try store.set(publicKey, forKey: publicKeyKey, scope: scope)
        } else {
            try? store.delete(publicKeyKey, scope: scope)
        }

        logger.info("Stored SSH key for server \(serverId.uuidString)")
    }

    private func getSSHKey(
        for serverId: UUID,
        scope: KeychainStorageScope
    ) throws -> (key: Data, passphrase: String?, publicKey: Data?)? {
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)
        let publicKeyKey = sshPublicKeyKey(for: serverId)

        // Try store first
        if let keyData = try store.get(keyKey, scope: scope) {
            var passphrase: String? = nil
            if let passphraseData = try store.get(passphraseKey, scope: scope) {
                passphrase = String(data: passphraseData, encoding: .utf8)
            }
            let publicKeyData = try store.get(publicKeyKey, scope: scope)
            return (key: keyData, passphrase: passphrase, publicKey: publicKeyData)
        }

        return nil
    }

    // MARK: - Full Credentials

    func getCredentials(for server: Server) throws -> ServerCredentials {
        var credentials = ServerCredentials(
            serverId: server.id,
            credentialBinding: ServerCredentialBinding(server: server)
        )

        logger.info("Getting credentials for server \(server.id.uuidString), authMethod: \(String(describing: server.authMethod))")

        if server.connectionMode == .tailscale {
            logger.info("Server \(server.id.uuidString) uses tailscale mode; skipping keychain credential lookup")
            return credentials
        }

        let resolution = try credentialStorageResolution(for: server)
        let scope = resolution?.scope ?? preferredStorageScope
        if resolution?.bindingMatches == false {
            try bindCredentials(to: server, scope: scope)
        }

        switch server.authMethod {
        case .password:
            credentials.password = try getPassword(for: server.id, scope: scope)
            logger.info("Password retrieved: \(credentials.password != nil)")
        case .sshKey:
            if let sshData = try getSSHKey(for: server.id, scope: scope) {
                credentials.privateKey = sshData.key
                credentials.publicKey = sshData.publicKey
            }
        case .sshKeyWithPassphrase:
            if let sshData = try getSSHKey(for: server.id, scope: scope) {
                credentials.privateKey = sshData.key
                credentials.passphrase = sshData.passphrase
                credentials.publicKey = sshData.publicKey
            }
        }

        if server.connectionMode == .cloudflare, server.cloudflareAccessMode == .serviceToken,
           let cloudflareToken = try getCloudflareServiceToken(
               for: server.id,
               scope: scope
           ) {
            credentials.cloudflareClientID = cloudflareToken.clientID
            credentials.cloudflareClientSecret = cloudflareToken.clientSecret
        }

        return credentials
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        guard credentials.serverId == server.id else {
            throw KeychainError.credentialServerMismatch
        }

        let scope = preferredStorageScope
        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let password = credentials.password {
                    try storePassword(
                        for: server.id,
                        password: password,
                        scope: scope
                    )
                }
            case .sshKey, .sshKeyWithPassphrase:
                if let privateKey = credentials.privateKey {
                    try storeSSHKey(
                        for: server.id,
                        privateKey: privateKey,
                        passphrase: credentials.passphrase,
                        publicKey: credentials.publicKey,
                        scope: scope
                    )
                }
            }
        }

        if server.connectionMode == .cloudflare,
           server.cloudflareAccessMode == .serviceToken,
           let clientID = credentials.cloudflareClientID,
           let clientSecret = credentials.cloudflareClientSecret {
            try storeCloudflareServiceToken(
                for: server.id,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope
            )
        } else {
            try deleteCloudflareServiceToken(
                for: server.id,
                scopes: [scope]
            )
        }

        try bindCredentials(to: server, scope: scope)
        if !isSyncEnabled() {
            try offlineChanges.record(.updated, for: .server(server.id))
        }
    }

    func prepareServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server,
        credentials: ServerCredentials
    ) throws {
        guard credentials.serverId == server.id else {
            throw KeychainError.credentialServerMismatch
        }

        let previous: StagedServerCredentialTransaction.Previous?
        if let previousServer,
           let resolution = try credentialStorageResolution(for: previousServer) {
            previous = StagedServerCredentialTransaction.Previous(
                bundle: try credentialBundle(
                    for: previousServer,
                    scope: resolution.scope
                ),
                scope: resolution.scope
            )
        } else {
            previous = nil
        }

        let staged = StagedServerCredentialTransaction(
            previous: previous,
            replacement: CredentialBundle(credentials: credentials, server: server),
            replacementScope: preferredStorageScope
        )
        let data = try JSONEncoder().encode(staged)
        let key = serverCredentialTransactionKey(id)
        try store.set(data, forKey: key, scope: .deviceOnly)
        guard try store.get(key, scope: .deviceOnly) == data else {
            throw KeychainError.encodingFailed
        }
    }

    func commitServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server
    ) throws {
        let key = serverCredentialTransactionKey(id)
        guard let data = try store.get(key, scope: .deviceOnly) else {
            throw KeychainError.itemNotFound
        }
        let staged = try JSONDecoder().decode(
            StagedServerCredentialTransaction.self,
            from: data
        )
        guard staged.replacement.serverID == server.id,
              staged.replacement.binding == ServerCredentialBinding(server: server) else {
            throw KeychainError.credentialServerMismatch
        }

        do {
            try replaceCredentialBundle(
                staged.replacement,
                for: server,
                scope: staged.replacementScope
            )
            if staged.replacementScope == .deviceOnly {
                try offlineChanges.record(.updated, for: .server(server.id))
            }
        } catch {
            do {
                try restoreCredentialBundle(
                    staged.previous,
                    previousServer: previousServer,
                    replacementServerID: server.id,
                    replacementScope: staged.replacementScope
                )
            } catch let rollbackError {
                throw ServerCredentialTransactionCommitError(
                    originalError: error,
                    rollbackError: rollbackError
                )
            }
            throw error
        }
    }

    func discardServerCredentialTransaction(id: UUID) throws {
        let key = serverCredentialTransactionKey(id)
        try store.delete(key, scope: .deviceOnly)
        guard try !store.contains(key, scope: .deviceOnly) else {
            throw KeychainError.itemNotFound
        }
    }

    func hasCredentials(for server: Server) throws -> Bool {
        try credentialStorageResolution(for: server) != nil
    }

    private func bindCredentials(
        to server: Server,
        scope: KeychainStorageScope
    ) throws {
        let binding = ServerCredentialBinding(server: server)
        let data = try JSONEncoder().encode(binding)
        try store.set(
            data,
            forKey: credentialBindingKey(for: server.id),
            scope: scope
        )
        logger.info("Bound credentials to server \(server.id.uuidString)")
    }

    // MARK: - Cloudflare Service Token

    private func storeCloudflareServiceToken(
        for serverId: UUID,
        clientID: String,
        clientSecret: String,
        scope: KeychainStorageScope
    ) throws {
        let idKey = cloudflareClientIDKey(for: serverId)
        let secretKey = cloudflareClientSecretKey(for: serverId)

        guard let idData = clientID.data(using: .utf8),
              let secretData = clientSecret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        try store.set(idData, forKey: idKey, scope: scope)
        try store.set(secretData, forKey: secretKey, scope: scope)
        logger.info("Stored Cloudflare service token for server \(serverId.uuidString)")
    }

    private func getCloudflareServiceToken(
        for serverId: UUID,
        scope: KeychainStorageScope
    ) throws -> (clientID: String, clientSecret: String)? {
        let idKey = cloudflareClientIDKey(for: serverId)
        let secretKey = cloudflareClientSecretKey(for: serverId)

        guard let idData = try store.get(idKey, scope: scope),
              let secretData = try store.get(secretKey, scope: scope),
              let clientID = String(data: idData, encoding: .utf8),
              let clientSecret = String(data: secretData, encoding: .utf8) else {
            return nil
        }

        return (clientID: clientID, clientSecret: clientSecret)
    }

    private func deleteCloudflareServiceToken(
        for serverId: UUID,
        scopes: [KeychainStorageScope]
    ) throws {
        try deleteCredentialKey(cloudflareClientIDKey(for: serverId), scopes: scopes)
        try deleteCredentialKey(cloudflareClientSecretKey(for: serverId), scopes: scopes)
    }

    // MARK: - Delete Operations

    func deleteCredentials(for serverId: UUID) throws {
        if !isSyncEnabled() {
            try offlineChanges.record(.deleted, for: .server(serverId))
        }
        let passwordKey = passwordKey(for: serverId)
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)
        let publicKeyKey = sshPublicKeyKey(for: serverId)
        let cloudflareIDKey = cloudflareClientIDKey(for: serverId)
        let cloudflareSecretKey = cloudflareClientSecretKey(for: serverId)
        let bindingKey = credentialBindingKey(for: serverId)

        for key in [
            passwordKey,
            keyKey,
            passphraseKey,
            publicKeyKey,
            cloudflareIDKey,
            cloudflareSecretKey,
            bindingKey
        ] {
            try deleteCredentialKey(key, scopes: KeychainStorageScope.allCases)
        }

        logger.info("Deleted credentials for server \(serverId.uuidString)")
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

    private func sshPublicKeyKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).publickey"
    }

    private func cloudflareClientIDKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).cloudflare.clientid"
    }

    private func cloudflareClientSecretKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).cloudflare.clientsecret"
    }

    private func credentialBindingKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).credential-binding.v1"
    }

    private func credentialKeys(for serverId: UUID) -> [String] {
        [
            passwordKey(for: serverId),
            sshKeyKey(for: serverId),
            sshPassphraseKey(for: serverId),
            sshPublicKeyKey(for: serverId),
            cloudflareClientIDKey(for: serverId),
            cloudflareClientSecretKey(for: serverId)
        ]
    }

    private func credentialBundleKeys(for serverID: UUID) -> [String] {
        credentialKeys(for: serverID) + [credentialBindingKey(for: serverID)]
    }

    private func serverCredentialTransactionKey(_ id: UUID) -> String {
        "server-credential-transaction.\(id.uuidString).v1"
    }

    private func credentialBundle(
        for server: Server,
        scope: KeychainStorageScope
    ) throws -> CredentialBundle {
        var credentials = ServerCredentials(serverId: server.id)
        credentials.password = try getPassword(for: server.id, scope: scope)
        if let key = try getSSHKey(for: server.id, scope: scope) {
            credentials.privateKey = key.key
            credentials.publicKey = key.publicKey
            credentials.passphrase = key.passphrase
        }
        if let token = try getCloudflareServiceToken(for: server.id, scope: scope) {
            credentials.cloudflareClientID = token.clientID
            credentials.cloudflareClientSecret = token.clientSecret
        }
        return CredentialBundle(credentials: credentials, server: server)
    }

    private func replaceCredentialBundle(
        _ bundle: CredentialBundle,
        for server: Server,
        scope: KeychainStorageScope
    ) throws {
        for key in credentialBundleKeys(for: server.id) {
            try store.delete(key, scope: scope)
        }

        if let password = bundle.password {
            try storePassword(for: server.id, password: password, scope: scope)
        }
        if let privateKey = bundle.privateKey {
            try storeSSHKey(
                for: server.id,
                privateKey: privateKey,
                passphrase: bundle.passphrase,
                publicKey: bundle.publicKey,
                scope: scope
            )
        }
        if let clientID = bundle.cloudflareClientID,
           let clientSecret = bundle.cloudflareClientSecret {
            try storeCloudflareServiceToken(
                for: server.id,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope
            )
        }
        try bindCredentials(to: server, scope: scope)

        guard try credentialBundle(for: server, scope: scope) == bundle else {
            throw KeychainError.decodingFailed
        }
    }

    private func restoreCredentialBundle(
        _ previous: StagedServerCredentialTransaction.Previous?,
        previousServer: Server?,
        replacementServerID: UUID,
        replacementScope: KeychainStorageScope
    ) throws {
        for key in credentialBundleKeys(for: replacementServerID) {
            try store.delete(key, scope: replacementScope)
        }
        guard let previous, let previousServer else { return }
        try replaceCredentialBundle(
            previous.bundle,
            for: previousServer,
            scope: previous.scope
        )
    }

    private struct CredentialStorageResolution {
        let scope: KeychainStorageScope
        let bindingMatches: Bool
    }

    private var preferredStorageScope: KeychainStorageScope {
        isSyncEnabled() ? .iCloud : .deviceOnly
    }

    private var readScopes: [KeychainStorageScope] {
        isSyncEnabled() ? [.iCloud, .deviceOnly] : [.deviceOnly]
    }

    private func credentialStorageResolution(
        for server: Server
    ) throws -> CredentialStorageResolution? {
        let currentBinding = ServerCredentialBinding(server: server)
        var firstStoredResolution: CredentialStorageResolution?

        for scope in readScopes {
            let hasCredentials = try credentialKeys(for: server.id).contains { key in
                try store.contains(key, scope: scope)
            }
            guard hasCredentials else { continue }

            let storedBinding: ServerCredentialBinding?
            if let data = try store.get(
                credentialBindingKey(for: server.id),
                scope: scope
            ) {
                storedBinding = try? JSONDecoder().decode(
                    ServerCredentialBinding.self,
                    from: data
                )
            } else {
                storedBinding = nil
            }
            let resolution = CredentialStorageResolution(
                scope: scope,
                bindingMatches: storedBinding == currentBinding
            )
            if resolution.bindingMatches {
                return resolution
            }
            if firstStoredResolution == nil {
                firstStoredResolution = resolution
            }
        }

        return firstStoredResolution
    }

    private func deleteCredentialKey(
        _ key: String,
        scopes: [KeychainStorageScope]
    ) throws {
        for scope in scopes {
            try store.delete(key, scope: scope)
        }
    }

    func synchronizeCredentialStorage(isEnabled: Bool) throws {
        try credentialOfflineWrites.resumePendingWrite()
        try oauthOfflineWrites.resumePendingWrite()
        if isEnabled {
            if offlineChanges.reconciliationPhase == .preparingOfflineSnapshot {
                try prepareOfflineCredentialSnapshot()
            }
            if offlineChanges.requiresSyncDisableCommit {
                try persistSyncEnabled(false)
                try offlineChanges.finishSyncDisableCommit()
            }
            try applyOfflineCredentialChangesToCloud()
            try persistSyncEnabled(true)
            if offlineChanges.reconciliationPhase == .localCleanup {
                do {
                    try finishLocalCredentialCleanup()
                } catch {
                    logger.error(
                        "Credential sync is active, but local credential cleanup remains pending: \(error.localizedDescription)"
                    )
                }
            }
        } else {
            try prepareOfflineCredentialSnapshot()
            try persistSyncEnabled(false)
            if offlineChanges.requiresSyncDisableCommit {
                do {
                    try offlineChanges.finishSyncDisableCommit()
                } catch {
                    logger.error(
                        "Credential snapshot is active, but its transition marker remains pending: \(error.localizedDescription)"
                    )
                }
            }
        }
        logger.info(
            "Prepared credential storage for iCloud sync enabled=\(isEnabled)"
        )
    }

    func handleSyncToggle(isEnabled: Bool) throws {
        try synchronizeCredentialStorage(isEnabled: isEnabled)
        if isEnabled {
            UserDefaults.standard.set(true, forKey: Self.iCloudMigrationKey)
        }
    }

    var hasPendingCredentialSyncWork: Bool {
        shouldResumeCredentialStorageOnLaunch
    }

    func removeCredentialsFromICloud() throws {
        guard !isSyncEnabled() else {
            throw CredentialSyncError.syncMustBeDisabled
        }

        try synchronizeCredentialStorage(isEnabled: false)
        let credentialKeys = try store.keys(in: .deviceOnly).filter(Self.isSynchronizableCredentialKey)
        let oauthKeys = try cloudflareTokenStore.keys(in: .deviceOnly).filter { $0.hasPrefix("oauth.") }
        var units = Set(credentialKeys.compactMap(credentialSyncUnit(forCredentialKey:)))
        units.formUnion(oauthKeys.map(CredentialSyncUnit.oauth))

        // A later re-enable must restore every local credential. Persist that
        // intent before removing any iCloud Keychain item.
        try offlineChanges.recordCloudRemovalRestoreIntent(for: units)
        try store.deleteAll(in: .iCloud, where: Self.isSynchronizableCredentialKey)
        try cloudflareTokenStore.deleteAll(in: .iCloud, where: { $0.hasPrefix("oauth.") })
    }

    private func prepareOfflineCredentialSnapshot() throws {
        switch offlineChanges.reconciliationPhase {
        case .remoteChanges:
            return
        case .localCleanup:
            try offlineChanges.beginOfflineSnapshotPreparation()
        case .preparingOfflineSnapshot:
            break
        case nil:
            try offlineChanges.beginOfflineSnapshotPreparation()
        }

        let credentialKeys = try replaceDeviceSnapshot(
            in: store,
            where: Self.isSynchronizableCredentialKey
        )
        let oauthKeys = try replaceDeviceSnapshot(
            in: cloudflareTokenStore,
            where: { $0.hasPrefix("oauth.") }
        )
        var units = Set(
            credentialKeys.compactMap(credentialSyncUnit(forCredentialKey:))
        )
        units.formUnion(
            oauthKeys.map(CredentialSyncUnit.oauth)
        )
        try offlineChanges.completeOfflineSnapshot(
            changes: Dictionary(uniqueKeysWithValues: units.map { ($0, .unchanged) })
        )
    }

    private func replaceDeviceSnapshot(
        in selectedStore: KeychainStore,
        where shouldCopy: (String) -> Bool
    ) throws -> [String] {
        let sourceKeys = try selectedStore.keys(in: .iCloud).filter(shouldCopy)
        let snapshot = try Dictionary(uniqueKeysWithValues: sourceKeys.map { key in
            guard let value = try selectedStore.get(key, scope: .iCloud) else {
                throw KeychainError.itemNotFound
            }
            return (key, value)
        })

        for key in sourceKeys {
            guard let value = snapshot[key] else { throw KeychainError.itemNotFound }
            try selectedStore.set(value, forKey: key, scope: .deviceOnly)
            guard try selectedStore.get(key, scope: .deviceOnly) == value else {
                throw KeychainError.copyVerificationFailed
            }
        }

        let expectedKeys = Set(sourceKeys)
        for key in try selectedStore.keys(in: .deviceOnly)
            where shouldCopy(key) && !expectedKeys.contains(key) {
            try selectedStore.delete(key, scope: .deviceOnly)
        }

        let finalKeys = try selectedStore.keys(in: .deviceOnly).filter(shouldCopy)
        guard Set(finalKeys) == expectedKeys else {
            throw KeychainError.copyVerificationFailed
        }
        for key in sourceKeys where try selectedStore.get(key, scope: .deviceOnly) != snapshot[key] {
            throw KeychainError.copyVerificationFailed
        }
        return sourceKeys
    }

    private var shouldResumeCredentialStorageOnLaunch: Bool {
        credentialOfflineWrites.hasPendingWrite
            || oauthOfflineWrites.hasPendingWrite
            || offlineChanges.reconciliationPhase == .preparingOfflineSnapshot
            || offlineChanges.requiresSyncDisableCommit
            || offlineChanges.reconciliationPhase == .localCleanup
            || (isSyncEnabled()
                && (offlineChanges.isTrackingOfflineChanges
                    || !UserDefaults.standard.bool(forKey: Self.iCloudMigrationKey)))
    }

    private func resumeCredentialStorageOnLaunch() throws {
        try credentialOfflineWrites.resumePendingWrite()
        try oauthOfflineWrites.resumePendingWrite()

        if offlineChanges.reconciliationPhase == .preparingOfflineSnapshot {
            try prepareOfflineCredentialSnapshot()
        }
        if offlineChanges.requiresSyncDisableCommit {
            try persistSyncEnabled(false)
            try offlineChanges.finishSyncDisableCommit()
            return
        }
        if offlineChanges.reconciliationPhase == .localCleanup, !isSyncEnabled() {
            try synchronizeCredentialStorage(isEnabled: false)
            return
        }
        if isSyncEnabled() {
            try synchronizeCredentialStorage(isEnabled: true)
        }
    }

    private func applyOfflineCredentialChangesToCloud() throws {
        if offlineChanges.reconciliationPhase == nil {
            let existingChanges = offlineChanges.snapshot()
            var units = Set(existingChanges.keys)
            for key in try store.keys(in: .deviceOnly) where Self.isSynchronizableCredentialKey(key) {
                if let unit = credentialSyncUnit(forCredentialKey: key) {
                    units.insert(unit)
                }
            }
            for key in try cloudflareTokenStore.keys(in: .deviceOnly) where key.hasPrefix("oauth.") {
                units.insert(.oauth(key))
            }
            guard !units.isEmpty else { return }
            try offlineChanges.beginOfflineTracking(
                changes: Dictionary(
                    uniqueKeysWithValues: units.map { unit in
                        (unit, existingChanges[unit] ?? .updated)
                    }
                )
            )
        }

        if offlineChanges.reconciliationPhase == .remoteChanges {
            var units = Set(offlineChanges.snapshot().keys)
            for key in try store.keys(in: .deviceOnly) where Self.isSynchronizableCredentialKey(key) {
                if let unit = credentialSyncUnit(forCredentialKey: key) {
                    units.insert(unit)
                }
            }
            for key in try cloudflareTokenStore.keys(in: .deviceOnly) where key.hasPrefix("oauth.") {
                units.insert(.oauth(key))
            }

            try reconcileSSHKeyChanges(offlineChanges.snapshot())
            for unit in units.sorted(by: { $0.storageKey < $1.storageKey }) {
                switch unit {
                case .sshKey, .legacySSHLibrary:
                    continue
                case .server, .oauth:
                    break
                }
                switch offlineChanges.change(for: unit) {
                case .updated:
                    try replaceCloudUnitFromDevice(unit)
                case .deleted:
                    try deleteCredentialUnit(unit, scopes: [.iCloud])
                case .unchanged, nil:
                    break
                }
            }
            try offlineChanges.markRemoteChangesApplied()
        }

    }

    private func finishLocalCredentialCleanup() throws {
        try store.deleteAll(in: .deviceOnly, where: Self.isSynchronizableCredentialKey)
        try cloudflareTokenStore.deleteAll(
            in: .deviceOnly,
            where: { $0.hasPrefix("oauth.") }
        )
        try offlineChanges.finishOnlineReconciliation()
    }

    private func reconcileSSHKeyChanges(
        _ snapshot: [CredentialSyncUnit: CredentialOfflineChange]
    ) throws {
        let localEntries = try sshKeyEntries(in: .deviceOnly)
        var changes: [UUID: CredentialOfflineChange] = [:]
        for (unit, change) in snapshot {
            if case .sshKey(let id) = unit {
                changes[id] = change
            }
        }
        if snapshot[.legacySSHLibrary] == .updated {
            for entry in localEntries where changes[entry.id] == nil {
                changes[entry.id] = .updated
            }
        }
        guard changes.values.contains(where: { $0 != .unchanged }) else { return }

        let localEntriesByID = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })
        var cloudEntries = try sshKeyEntries(in: .iCloud)
        for (id, change) in changes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            switch change {
            case .unchanged:
                continue
            case .updated:
                guard let entry = localEntriesByID[id],
                      let privateKey = try store.get(storedKeyDataKey(for: id), scope: .deviceOnly) else {
                    throw KeychainError.itemNotFound
                }
                if let cloudEntry = cloudEntries.first(where: { $0.id == id }),
                   cloudEntry.updatedAt > entry.updatedAt {
                    continue
                }
                try store.set(privateKey, forKey: storedKeyDataKey(for: id), scope: .iCloud)
                guard try store.get(storedKeyDataKey(for: id), scope: .iCloud) == privateKey else {
                    throw KeychainError.copyVerificationFailed
                }

                let passphraseKey = storedKeyPassphraseKey(for: id)
                if let passphrase = try store.get(passphraseKey, scope: .deviceOnly) {
                    try store.set(passphrase, forKey: passphraseKey, scope: .iCloud)
                    guard try store.get(passphraseKey, scope: .iCloud) == passphrase else {
                        throw KeychainError.copyVerificationFailed
                    }
                } else {
                    try store.delete(passphraseKey, scope: .iCloud)
                }

                if let index = cloudEntries.firstIndex(where: { $0.id == id }) {
                    cloudEntries[index] = entry
                } else {
                    cloudEntries.append(entry)
                }
            case .deleted:
                if let deletionDate = offlineChanges.changeDate(for: .sshKey(id)),
                   let cloudEntry = cloudEntries.first(where: { $0.id == id }),
                   cloudEntry.updatedAt > deletionDate {
                    continue
                }
                cloudEntries.removeAll { $0.id == id }
                try store.delete(storedKeyDataKey(for: id), scope: .iCloud)
                try store.delete(storedKeyPassphraseKey(for: id), scope: .iCloud)
            }
        }

        let indexData = try JSONEncoder().encode(cloudEntries)
        try store.set(indexData, forKey: sshKeysIndexKey, scope: .iCloud)
        guard try store.get(sshKeysIndexKey, scope: .iCloud) == indexData else {
            throw KeychainError.copyVerificationFailed
        }
    }

    private func sshKeyEntries(in scope: KeychainStorageScope) throws -> [SSHKeyEntry] {
        guard let data = try store.get(sshKeysIndexKey, scope: scope) else { return [] }
        do {
            return try JSONDecoder().decode([SSHKeyEntry].self, from: data)
        } catch {
            throw KeychainError.decodingFailed
        }
    }

    private func replaceCloudUnitFromDevice(_ unit: CredentialSyncUnit) throws {
        let selectedStore = keychainStore(for: unit)
        let keys = try credentialKeys(
            for: unit,
            store: selectedStore,
            scope: .deviceOnly,
            includingOrphans: false
        )
        let values = try Dictionary(uniqueKeysWithValues: keys.map { key in
            guard let value = try selectedStore.get(key, scope: .deviceOnly) else {
                throw KeychainError.itemNotFound
            }
            return (key, value)
        })

        try deleteCredentialUnit(unit, scopes: [.iCloud])
        for key in keys {
            guard let value = values[key] else { throw KeychainError.itemNotFound }
            try selectedStore.set(value, forKey: key, scope: .iCloud)
        }
        for key in keys {
            guard try selectedStore.get(key, scope: .iCloud) == values[key] else {
                throw KeychainError.copyVerificationFailed
            }
        }
    }

    private func deleteCredentialUnit(
        _ unit: CredentialSyncUnit,
        scopes: [KeychainStorageScope]
    ) throws {
        let selectedStore = keychainStore(for: unit)
        for scope in scopes {
            let keys = try credentialKeys(for: unit, store: selectedStore, scope: scope)
            for key in keys {
                try selectedStore.delete(key, scope: scope)
            }
        }
    }

    private func keychainStore(for unit: CredentialSyncUnit) -> KeychainStore {
        if case .oauth = unit { return cloudflareTokenStore }
        return store
    }

    private func credentialKeys(
        for unit: CredentialSyncUnit,
        store selectedStore: KeychainStore,
        scope: KeychainStorageScope,
        includingOrphans: Bool = true
    ) throws -> [String] {
        switch unit {
        case .server(let id):
            return credentialBundleKeys(for: id).filter {
                (try? selectedStore.contains($0, scope: scope)) == true
            }
        case .sshKey(let id):
            return [storedKeyDataKey(for: id), storedKeyPassphraseKey(for: id)].filter {
                (try? selectedStore.contains($0, scope: scope)) == true
            }
        case .legacySSHLibrary:
            let allKeys = try selectedStore.keys(in: scope)
            guard !includingOrphans,
                  let indexData = try selectedStore.get(sshKeysIndexKey, scope: scope),
                  let entries = try? JSONDecoder().decode([SSHKeyEntry].self, from: indexData) else {
                return allKeys.filter {
                    $0 == sshKeysIndexKey || $0.hasPrefix("sshkey.")
                }
            }
            let selectedKeys = Set(entries.flatMap { entry in
                [storedKeyDataKey(for: entry.id), storedKeyPassphraseKey(for: entry.id)]
            })
            return allKeys.filter { $0 == sshKeysIndexKey || selectedKeys.contains($0) }
        case .oauth(let key):
            return try selectedStore.contains(key, scope: scope) ? [key] : []
        }
    }

    private func credentialSyncUnit(forCredentialKey key: String) -> CredentialSyncUnit? {
        if key == sshKeysIndexKey {
            return nil
        }
        if key.hasPrefix("sshkey.") {
            let components = key.split(separator: ".", maxSplits: 2)
            guard components.count == 3,
                  let id = UUID(uuidString: String(components[1])) else {
                return nil
            }
            return .sshKey(id)
        }
        guard key.hasPrefix("server.") else { return nil }
        let components = key.split(separator: ".", maxSplits: 2)
        guard components.count >= 2,
              let id = UUID(uuidString: String(components[1])) else {
            return nil
        }
        return .server(id)
    }

    nonisolated static func isSynchronizableCredentialKey(_ key: String) -> Bool {
        if key == "vvterm.sshkeys.index" {
            return true
        }
        if key.hasPrefix("sshkey.") {
            return key.hasSuffix(".data") || key.hasSuffix(".passphrase")
        }
        guard key.hasPrefix("server.") else { return false }
        return [
            ".password",
            ".sshkey",
            ".passphrase",
            ".publickey",
            ".cloudflare.clientid",
            ".cloudflare.clientsecret",
            ".credential-binding.v1"
        ].contains { key.hasSuffix($0) }
    }

    // MARK: - Reusable SSH Keys (Keychain Library)

    private let sshKeysIndexKey = "vvterm.sshkeys.index"

    /// Get all stored SSH key entries (metadata only, not the actual keys)
    func getStoredSSHKeys() -> [SSHKeyEntry] {
        for scope in readScopes {
            if let data = try? store.get(sshKeysIndexKey, scope: scope),
               let keys = try? JSONDecoder().decode([SSHKeyEntry].self, from: data) {
                return keys.sorted { $0.createdAt > $1.createdAt }
            }
        }
        return []
    }

    /// Save the SSH key index
    private func saveSSHKeysIndex(_ keys: [SSHKeyEntry]) throws {
        let data = try JSONEncoder().encode(keys)
        try store.set(data, forKey: sshKeysIndexKey, scope: preferredStorageScope)
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

        var keys = getStoredSSHKeys()
        keys.append(entry)
        let indexData = try JSONEncoder().encode(keys)
        if isSyncEnabled() {
            try store.set(
                privateKey,
                forKey: storedKeyDataKey(for: entry.id),
                scope: .iCloud
            )
            if let passphrase, !passphrase.isEmpty,
               let passphraseData = passphrase.data(using: .utf8) {
                try store.set(
                    passphraseData,
                    forKey: storedKeyPassphraseKey(for: entry.id),
                    scope: .iCloud
                )
            }
            try store.set(indexData, forKey: sshKeysIndexKey, scope: .iCloud)
        } else {
            let passphraseData = passphrase
                .flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
            try credentialOfflineWrites.commitUpdate(
                for: .sshKey(entry.id),
                operations: [
                    .init(targetKey: storedKeyDataKey(for: entry.id), value: privateKey),
                    .init(
                        targetKey: storedKeyPassphraseKey(for: entry.id),
                        value: passphraseData
                    ),
                    .init(targetKey: sshKeysIndexKey, value: indexData)
                ]
            )
        }

        logger.info("Stored SSH key '\(name)' in keychain library")
        return entry
    }

    /// Get the actual key data for a stored SSH key
    func getStoredSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)? {
        var storedScope: KeychainStorageScope?
        var storedKeyData: Data?
        for scope in readScopes {
            if let keyData = try store.get(storedKeyDataKey(for: keyId), scope: scope) {
                storedScope = scope
                storedKeyData = keyData
                break
            }
        }
        guard let scope = storedScope, let keyData = storedKeyData else { return nil }

        var passphrase: String? = nil
        if let passphraseData = try store.get(
            storedKeyPassphraseKey(for: keyId),
            scope: scope
        ) {
            passphrase = String(data: passphraseData, encoding: .utf8)
        }

        return (key: keyData, passphrase: passphrase)
    }

    /// Delete a stored SSH key from the library
    func deleteStoredSSHKey(_ keyId: UUID) throws {
        if !isSyncEnabled() {
            try offlineChanges.record(.deleted, for: .sshKey(keyId))
        }
        var keys = getStoredSSHKeys()
        keys.removeAll { $0.id == keyId }
        try saveSSHKeysIndex(keys)

        // Delete key data
        try deleteCredentialKey(
            storedKeyDataKey(for: keyId),
            scopes: KeychainStorageScope.allCases
        )
        try deleteCredentialKey(
            storedKeyPassphraseKey(for: keyId),
            scopes: KeychainStorageScope.allCases
        )

        logger.info("Deleted SSH key \(keyId.uuidString) from keychain library")
    }

    /// Update a stored SSH key's name
    func updateStoredSSHKeyName(_ keyId: UUID, name: String) throws {
        var keys = getStoredSSHKeys()
        guard let index = keys.firstIndex(where: { $0.id == keyId }) else {
            throw KeychainError.itemNotFound
        }
        keys[index].name = name
        keys[index].updatedAt = Date()
        let indexData = try JSONEncoder().encode(keys)
        if isSyncEnabled() {
            try store.set(indexData, forKey: sshKeysIndexKey, scope: .iCloud)
        } else {
            try credentialOfflineWrites.commitUpdate(
                for: .sshKey(keyId),
                operations: [.init(targetKey: sshKeysIndexKey, value: indexData)]
            )
        }
        logger.info("Updated SSH key name to '\(name)'")
    }

    private func storedKeyDataKey(for keyId: UUID) -> String {
        "sshkey.\(keyId.uuidString).data"
    }

    private func storedKeyPassphraseKey(for keyId: UUID) -> String {
        "sshkey.\(keyId.uuidString).passphrase"
    }
}

nonisolated struct ServerCredentialTransactionCommitError: Error, Sendable {
    let originalErrorDescription: String
    let rollbackErrorDescription: String

    init(originalError: Error, rollbackError: Error) {
        originalErrorDescription = String(describing: originalError)
        rollbackErrorDescription = String(describing: rollbackError)
    }
}

// KeychainError is defined in KeychainStore.swift
// ServerCredentials is defined in Server.swift
