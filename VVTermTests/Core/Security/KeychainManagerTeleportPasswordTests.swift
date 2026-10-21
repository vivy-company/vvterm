import Foundation
import Testing
@testable import VVTerm

@MainActor
@Suite(.serialized)
struct KeychainManagerTeleportPasswordTests {
    @Test(arguments: [false, true])
    func savedPasswordUsesTheServerScopeWithoutSSHKeys(syncEnabled: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: syncEnabled)
        let server = try makeServer()
        let credentials = ServerCredentials(
            serverId: server.id, password: "test-password",
            privateKey: Data("unused-private-key".utf8), publicKey: Data("unused-public-key".utf8),
            passphrase: "unused-passphrase", cloudflareClientID: "unused-id",
            cloudflareClientSecret: "unused-secret"
        )

        try manager.storeCredentials(credentials, for: server)

        let loaded = try manager.getCredentials(for: server)
        let scope: KeychainStorageScope = syncEnabled ? .iCloud : .deviceOnly
        #expect(server.authMethod == nil)
        #expect(loaded.password == credentials.password)
        #expect(loaded.privateKey == nil)
        #expect(loaded.passphrase == nil)
        #expect(loaded.cloudflareClientSecret == nil)
        #expect(try fixture.store.keys(in: scope) == [teleportKey(server)])
        let data = try #require(try fixture.store.get(teleportKey(server), scope: scope))
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(record["privateKey"] == nil)
        #expect(record["passphrase"] == nil)
        #expect(record["cloudflareClientSecret"] == nil)
        #expect(try fixture.store.keys(in: scope.alternate).isEmpty)
        if !syncEnabled {
            #expect(fixture.offlineChanges.change(for: .server(server.id)) == .updated)
        }
    }

    @Test(arguments: AccountChange.allCases)
    func anotherAccountCannotReadOrRebindThePassword(change: AccountChange) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let original = try makeServer()
        try manager.storeCredentials(
            ServerCredentials(serverId: original.id, password: "test-password"), for: original
        )
        var proxy = "https://proxy.example.test"
        var account = "alice"
        switch change {
        case .proxy: proxy = "https://other.example.test"
        case .port: proxy = "https://proxy.example.test:8443"
        case .account: account = "bob"
        case .accountCase: account = "Alice"
        }
        let changed = try makeServer(id: original.id, proxy: proxy, account: account)
        let recordBefore = try fixture.store.get(teleportKey(original), scope: .iCloud)

        let loaded = try manager.getCredentials(for: changed)

        #expect(loaded.password == nil)
        #expect(try fixture.store.get(teleportKey(original), scope: .iCloud) == recordBefore)
    }

    @Test
    func anSSHPasswordCannotBeReadAsATeleportPassword() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let teleport = try makeServer()
        var ssh = teleport
        ssh.connectionMode = .standard
        ssh.authMethod = .password
        try manager.storeCredentials(
            ServerCredentials(serverId: ssh.id, password: "ssh-password"), for: ssh
        )

        #expect(try manager.getCredentials(for: teleport).password == nil)
        #expect(try manager.getCredentials(for: ssh).password == "ssh-password")
    }

    @Test
    func canonicalProxyAndSameAccountAllowNodeAndLoginChanges() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let original = try makeServer(proxy: "HTTPS://PROXY.EXAMPLE.TEST:443/")
        try manager.storeCredentials(
            ServerCredentials(serverId: original.id, password: "test-password"), for: original
        )
        var changed = try makeServer(id: original.id)
        changed.name = "Renamed"
        changed.username = "other-login"
        changed.transportConfiguration = .teleport(try TeleportServerConfiguration(
            profile: try #require(changed.teleportConfiguration?.profile),
            clusterName: "other-cluster", nodeID: "other-node"
        ))

        #expect(try manager.getCredentials(for: changed).password == "test-password")
        let duplicate = try makeServer()
        #expect(try manager.getCredentials(for: duplicate).password == nil)
    }

    @Test
    func changingToSSHDoesNotReadOrRebindTheTeleportPassword() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        try manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "test-password"), for: server
        )
        let recordBefore = try fixture.store.get(teleportKey(server), scope: .iCloud)
        var changed = server
        changed.connectionMode = .standard
        changed.authMethod = .password
        changed.host = "ssh.example.test"

        #expect(try manager.getCredentials(for: changed).password == nil)
        #expect(try fixture.store.get(teleportKey(server), scope: .iCloud) == recordBefore)
        #expect(try fixture.store.get(passwordKey(server), scope: .iCloud) == nil)

        try manager.storeCredentials(
            ServerCredentials(serverId: changed.id, password: "ssh-password"), for: changed
        )
        #expect(try manager.getCredentials(for: changed).password == "ssh-password")
        #expect(try fixture.store.get(teleportKey(server), scope: .iCloud) == nil)
        #expect(try manager.getCredentials(for: server).password == nil)
    }

    @Test(arguments: [false, true])
    func separateSSHItemsDoNotSupplyATeleportPassword(invalidBinding: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        try fixture.store.set(Data("test-password".utf8), forKey: passwordKey(server), scope: .iCloud)
        let binding = invalidBinding ? Data("invalid".utf8)
            : try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.store.set(binding, forKey: bindingKey(server), scope: .iCloud)

        #expect(try manager.getCredentials(for: server).password == nil)
        #expect(try fixture.store.get(bindingKey(server), scope: .iCloud) == binding)
    }

    @Test(arguments: [false, true])
    func separatePasswordAndBindingUpdatesCannotChangeAtomicCredentials(oldBinding: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let original = try makeServer()
        let changed = try makeServer(id: original.id, proxy: "https://other.example.test", account: "bob")
        try manager.storeCredentials(
            ServerCredentials(serverId: original.id, password: "original-password"), for: original
        )
        try fixture.store.set(Data("other-password".utf8), forKey: passwordKey(original), scope: .iCloud)
        try fixture.store.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: oldBinding ? original : changed)),
            forKey: bindingKey(original), scope: .iCloud
        )

        #expect(try manager.getCredentials(for: original).password == "original-password")
        #expect(try manager.getCredentials(for: changed).password == nil)
    }

    @Test(arguments: [false, true])
    func cloudRecordStopsFallbackToAnOlderLocalPassword(cleared: Bool) throws {
        let fixture = Fixture()
        let local = fixture.manager(syncEnabled: false)
        let cloud = fixture.manager(syncEnabled: true)
        let original = try makeServer()
        try local.storeCredentials(
            ServerCredentials(serverId: original.id, password: "stale-local-password"), for: original
        )
        let cloudServer = cleared ? original : try makeServer(id: original.id, account: "bob")
        try cloud.storeCredentials(
            ServerCredentials(serverId: original.id, password: cleared ? nil : "other-password"), for: cloudServer
        )

        #expect(try cloud.getCredentials(for: original).password == nil)
        #expect(try fixture.store.get(teleportKey(original), scope: .iCloud) != nil)
        #expect(try local.getCredentials(for: original).password == "stale-local-password")
    }

    @Test
    func corruptCloudRecordReportsFailureWithoutUsingTheLocalPassword() throws {
        let fixture = Fixture()
        let local = fixture.manager(syncEnabled: false)
        let cloud = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        try local.storeCredentials(
            ServerCredentials(serverId: server.id, password: "local-password"), for: server
        )
        try fixture.store.set(Data("invalid".utf8), forKey: teleportKey(server), scope: .iCloud)

        do {
            _ = try cloud.getCredentials(for: server)
            Issue.record("Expected a corrupt-record error")
        } catch KeychainError.decodingFailed {
            // Expected; the stale local value must not hide this error.
        } catch {
            Issue.record("Expected KeychainError.decodingFailed")
        }
        #expect(try local.getCredentials(for: server).password == "local-password")
    }

    @Test
    func copiedRecordWithAnotherServerIDIsRejected() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let original = try makeServer()
        let other = try makeServer()
        try manager.storeCredentials(
            ServerCredentials(serverId: other.id, password: "other-password"), for: other
        )
        let data = try #require(try fixture.store.get(teleportKey(other), scope: .iCloud))
        try fixture.store.set(data, forKey: teleportKey(original), scope: .iCloud)

        do {
            _ = try manager.getCredentials(for: original)
            Issue.record("Expected a server mismatch error")
        } catch KeychainError.credentialServerMismatch {
            // Expected.
        } catch {
            Issue.record("Expected KeychainError.credentialServerMismatch")
        }
    }

    @Test
    func syncToggleAndOfflineDeletionUseTheExistingServerUnit() throws {
        let fixture = Fixture()
        let server = try makeServer()
        let cloud = fixture.manager(syncEnabled: true)
        let local = fixture.manager(syncEnabled: false)
        try cloud.storeCredentials(
            ServerCredentials(serverId: server.id, password: "first-password"), for: server
        )
        #expect(try local.getCredentials(for: server).password == nil)
        try cloud.synchronizeCredentialStorage(isEnabled: false)
        #expect(try local.getCredentials(for: server).password == "first-password")
        try local.storeCredentials(
            ServerCredentials(serverId: server.id, password: "updated-password"), for: server
        )
        try local.synchronizeCredentialStorage(isEnabled: true)
        #expect(try cloud.getCredentials(for: server).password == "updated-password")
        #expect(try fixture.store.get(teleportKey(server), scope: .deviceOnly) == nil)

        try cloud.synchronizeCredentialStorage(isEnabled: false)
        try local.deleteCredentials(for: server.id)
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .deleted)
        try local.synchronizeCredentialStorage(isEnabled: true)
        #expect(try cloud.getCredentials(for: server).password == nil)
        #expect(try fixture.store.get(teleportKey(server), scope: .iCloud) == nil)
    }

    @Test
    func saveTransactionStagesPasswordAndCanClearItWithoutStoringSSHKeys() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        try manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "old-password"), for: server
        )
        let discardedID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: discardedID, previousServer: server, server: server,
            credentials: ServerCredentials(serverId: server.id, password: "discarded-password")
        )
        try manager.discardServerCredentialTransaction(id: discardedID)
        #expect(try manager.getCredentials(for: server).password == "old-password")

        let savedID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: savedID, previousServer: server, server: server,
            credentials: ServerCredentials(
                serverId: server.id, password: "new-password", privateKey: Data("unused-key".utf8)
            )
        )
        try manager.commitServerCredentialTransaction(id: savedID, previousServer: server, server: server)
        try manager.discardServerCredentialTransaction(id: savedID)
        #expect(try manager.getCredentials(for: server).password == "new-password")
        #expect(try fixture.store.get("server.\(server.id.uuidString).sshkey", scope: .iCloud) == nil)

        let clearedID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: clearedID, previousServer: server, server: server,
            credentials: ServerCredentials(serverId: server.id, password: "")
        )
        try manager.commitServerCredentialTransaction(id: clearedID, previousServer: server, server: server)
        try manager.discardServerCredentialTransaction(id: clearedID)
        #expect(try manager.getCredentials(for: server).password == nil)
        #expect(try fixture.store.get(passwordKey(server), scope: .iCloud) == nil)
        #expect(try fixture.store.get(teleportKey(server), scope: .iCloud) != nil)
        #expect(try fixture.store.keys(in: .deviceOnly).isEmpty)
    }

    @Test(arguments: [false, true])
    func failedSaveRestoresThePreviousPassword(metadataChangedToSSH: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: false)
        let server = try makeServer()
        try manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "old-password"), for: server
        )
        var target = server
        if metadataChangedToSSH {
            target.connectionMode = .standard
            target.authMethod = .password
        }
        let transactionID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: transactionID, previousServer: target, server: target,
            credentials: ServerCredentials(serverId: server.id, password: "new-password")
        )
        // The change marker must fail after the password write when sync is being completed.
        try fixture.offlineChanges.markRemoteChangesApplied()

        #expect(throws: CredentialSyncError.offlineReconciliationPending) {
            try manager.commitServerCredentialTransaction(
                id: transactionID, previousServer: target, server: target
            )
        }

        #expect(try manager.getCredentials(for: server).password == "old-password")
        try manager.discardServerCredentialTransaction(id: transactionID)
        #expect(try fixture.store.keys(in: .deviceOnly) == [teleportKey(server)])
    }

    enum AccountChange: CaseIterable { case proxy, port, account, accountCase }

    private func makeServer(
        id: UUID = UUID(), proxy: String = "https://proxy.example.test", account: String = "alice"
    ) throws -> Server {
        Server(
            id: id, workspaceId: UUID(), name: "Teleport", host: "node-id", username: "deploy",
            connectionMode: .teleport,
            teleportConfiguration: try TeleportServerConfiguration(
                profile: TeleportProfileConfiguration(proxyURL: proxy, account: account),
                clusterName: "root.example.test", nodeID: "node-id"
            )
        )
    }

    private func passwordKey(_ server: Server) -> String { "server.\(server.id.uuidString).password" }
    private func bindingKey(_ server: Server) -> String { "server.\(server.id.uuidString).credential-binding.v1" }
    private func teleportKey(_ server: Server) -> String { "server.\(server.id.uuidString).teleport-credentials.v1" }

    @MainActor
    private final class Fixture {
        private let suiteName = "KeychainManagerTeleportPasswordTests.\(UUID().uuidString)"
        private let defaults: UserDefaults
        let store: KeychainStore
        let offlineChanges: CredentialOfflineChangeStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            store = KeychainStore(
                service: KeychainManager.credentialService, backing: InMemoryKeychainStoreBacking()
            )
            offlineChanges = CredentialOfflineChangeStore(defaults: defaults)
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        func manager(syncEnabled: Bool) -> KeychainManager {
            KeychainManager(
                store: store, cloudflareTokenStore: KeychainStore(
                    service: KeychainManager.cloudflareTokenService, backing: InMemoryKeychainStoreBacking()
                ),
                isSyncEnabled: { syncEnabled }, persistSyncEnabled: { _ in },
                offlineChanges: offlineChanges
            )
        }
    }
}
