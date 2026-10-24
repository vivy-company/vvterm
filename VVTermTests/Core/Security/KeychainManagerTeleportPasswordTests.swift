import Foundation
import Testing
@testable import VVTerm

@MainActor
struct KeychainManagerTeleportPasswordTests {
    @Test(arguments: [false, true])
    func teleportReturnsBoundEmptyCredentialsAndStoresNoPassword(syncEnabled: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: syncEnabled)
        let server = try makeServer()
        try manager.storeCredentials(ServerCredentials(
            serverId: server.id, password: "unused-password", privateKey: Data("unused-key".utf8),
            passphrase: "unused-passphrase", cloudflareClientID: "unused-id",
            cloudflareClientSecret: "unused-secret"
        ), for: server)

        let result = try manager.getCredentials(for: server)
        #expect(result.isAuthorized(for: server))
        #expect(result.password == nil)
        #expect(result.privateKey == nil)
        #expect(result.passphrase == nil)
        #expect(result.cloudflareClientID == nil)
        #expect(result.cloudflareClientSecret == nil)
        #expect(try fixture.store.keys(in: .iCloud).isEmpty)
        #expect(try fixture.store.keys(in: .deviceOnly).isEmpty)
        #expect(fixture.offlineChanges.snapshot().isEmpty)
    }

    @Test(arguments: [false, true])
    func approvedLoadOrSaveDeletesOnlyTheLegacyItem(saving: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        let other = try makeServer()
        for scope in KeychainStorageScope.allCases {
            try fixture.store.set(Data("invalid-old-record".utf8), forKey: teleportKey(server), scope: scope)
            try fixture.store.set(Data("other-entry".utf8), forKey: teleportKey(other), scope: scope)
            try fixture.store.set(Data("ssh-password".utf8), forKey: passwordKey(server), scope: scope)
            try fixture.store.set(Data("ssh-key".utf8), forKey: sshKey(server), scope: scope)
            try fixture.store.set(Data("cloudflare-secret".utf8), forKey: cloudflareKey(server), scope: scope)
            try fixture.store.set(Data("binding".utf8), forKey: bindingKey(server), scope: scope)
            try fixture.store.set(Data("device-identity".utf8), forKey: "device.identity", scope: scope)
        }
        let expected = fixture.backing.snapshot().filter { $0.key.key != teleportKey(server) }
        if saving {
            try manager.storeCredentials(ServerCredentials(serverId: server.id), for: server)
        } else {
            #expect(try manager.getCredentials(for: server).password == nil)
        }
        #expect(fixture.backing.snapshot() == expected)
    }

    @Test
    func offlineCleanupDefersCloudDeletionAndPreservesSSHWhenSyncReturns() throws {
        let fixture = Fixture()
        let cloud = fixture.manager(syncEnabled: true)
        let local = fixture.manager(syncEnabled: false)
        let server = try makeServer()
        let ssh = makeSSHServer(from: server)
        try cloud.storeCredentials(ServerCredentials(serverId: server.id, password: "ssh-password"), for: ssh)
        try cloud.synchronizeCredentialStorage(isEnabled: false)
        for scope in KeychainStorageScope.allCases {
            try fixture.store.set(Data("invalid-old-record".utf8), forKey: teleportKey(server), scope: scope)
        }

        #expect(try local.getCredentials(for: server).password == nil)
        #expect(try !fixture.store.contains(teleportKey(server), scope: .deviceOnly))
        #expect(try fixture.store.contains(teleportKey(server), scope: .iCloud))
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .updated)
        #expect(try local.getCredentials(for: ssh).password == "ssh-password")

        try local.synchronizeCredentialStorage(isEnabled: true)
        #expect(try !fixture.store.contains(teleportKey(server), scope: .iCloud))
        #expect(try cloud.getCredentials(for: ssh).password == "ssh-password")
        #expect(try fixture.store.keys(in: .deviceOnly).isEmpty)
    }

    @Test
    func snapshotDoesNotCopyLegacyRecordsAndEnableRemovesCloudOnlyRecords() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        try fixture.store.set(Data("invalid-old-record".utf8), forKey: teleportKey(server), scope: .iCloud)

        try manager.synchronizeCredentialStorage(isEnabled: false)
        #expect(try !fixture.store.contains(teleportKey(server), scope: .deviceOnly))
        #expect(try fixture.store.contains(teleportKey(server), scope: .iCloud))
        try manager.synchronizeCredentialStorage(isEnabled: true)
        #expect(try !fixture.store.contains(teleportKey(server), scope: .iCloud))
    }

    @Test(arguments: [false, true])
    func cleanupFailureIsReportedAndCanBeRetried(syncEnabled: Bool) throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: syncEnabled)
        let server = try makeServer()
        let scope: KeychainStorageScope = syncEnabled ? .iCloud : .deviceOnly
        try fixture.store.set(Data("invalid-old-record".utf8), forKey: teleportKey(server), scope: scope)
        fixture.backing.failDeletes(from: scope, service: fixture.store.service, key: teleportKey(server))

        #expect(throws: InMemoryKeychainStoreBacking.Failure.deleteRejected) {
            _ = try manager.getCredentials(for: server)
        }
        #expect(try fixture.store.contains(teleportKey(server), scope: scope))
        fixture.backing.allowDeletes(from: scope, service: fixture.store.service, key: teleportKey(server))
        #expect(try manager.getCredentials(for: server).isAuthorized(for: server))
        #expect(try !fixture.store.contains(teleportKey(server), scope: scope))
    }

    @Test
    func stagedTeleportSaveContainsNoPasswordAndKeepsOrdinarySSHCredentials() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        let ssh = makeSSHServer(from: server)
        try manager.storeCredentials(ServerCredentials(serverId: server.id, password: "ssh-password"), for: ssh)
        let original = fixture.backing.snapshot()
        let transactionID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: transactionID, previousServer: server, server: server,
            credentials: ServerCredentials(serverId: server.id, password: "unused-password")
        )
        let staged = try #require(try fixture.store.get(
            "server-credential-transaction.\(transactionID.uuidString).v1", scope: .deviceOnly
        ))
        #expect(!String(decoding: staged, as: UTF8.self).contains("unused-password"))
        try manager.commitServerCredentialTransaction(id: transactionID, previousServer: server, server: server)
        try manager.discardServerCredentialTransaction(id: transactionID)

        #expect(fixture.backing.snapshot() == original)
        #expect(try manager.getCredentials(for: ssh).password == "ssh-password")
    }

    @Test
    func failedTeleportSaveNeverDeletesOrdinarySSHCredentials() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: true)
        let server = try makeServer()
        let ssh = makeSSHServer(from: server)
        try manager.storeCredentials(ServerCredentials(serverId: server.id, password: "ssh-password"), for: ssh)
        try fixture.store.set(Data("old-record".utf8), forKey: teleportKey(server), scope: .iCloud)
        fixture.backing.failDeletes(from: .iCloud, service: fixture.store.service, key: teleportKey(server))
        let transactionID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: transactionID, previousServer: ssh, server: server,
            credentials: ServerCredentials(serverId: server.id)
        )
        #expect(throws: InMemoryKeychainStoreBacking.Failure.deleteRejected) {
            try manager.commitServerCredentialTransaction(id: transactionID, previousServer: ssh, server: server)
        }
        #expect(try manager.getCredentials(for: ssh).password == "ssh-password")
        try manager.discardServerCredentialTransaction(id: transactionID)
    }

    @Test
    func failedOrdinarySSHSaveStillRestoresItsPassword() throws {
        let fixture = Fixture()
        let manager = fixture.manager(syncEnabled: false)
        let ssh = makeSSHServer(from: try makeServer())
        try manager.storeCredentials(ServerCredentials(serverId: ssh.id, password: "old-password"), for: ssh)
        let transactionID = UUID()
        try manager.prepareServerCredentialTransaction(
            id: transactionID, previousServer: ssh, server: ssh,
            credentials: ServerCredentials(serverId: ssh.id, password: "new-password")
        )
        try fixture.offlineChanges.markRemoteChangesApplied()
        #expect(throws: CredentialSyncError.offlineReconciliationPending) {
            try manager.commitServerCredentialTransaction(id: transactionID, previousServer: ssh, server: ssh)
        }
        #expect(try manager.getCredentials(for: ssh).password == "old-password")
        try manager.discardServerCredentialTransaction(id: transactionID)
    }

    private func makeServer() throws -> Server {
        Server(
            workspaceId: UUID(), name: "Teleport", host: "node-id", username: "deploy",
            connectionMode: .teleport,
            teleportConfiguration: try TeleportServerConfiguration(
                profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
                clusterName: "root.example.test", nodeID: "node-id"
            )
        )
    }

    private func makeSSHServer(from server: Server) -> Server {
        var ssh = server
        ssh.connectionMode = .standard
        ssh.authMethod = .password
        return ssh
    }

    private func passwordKey(_ server: Server) -> String { "server.\(server.id.uuidString).password" }
    private func sshKey(_ server: Server) -> String { "server.\(server.id.uuidString).sshkey" }
    private func cloudflareKey(_ server: Server) -> String { "server.\(server.id.uuidString).cloudflare.clientsecret" }
    private func bindingKey(_ server: Server) -> String { "server.\(server.id.uuidString).credential-binding.v1" }
    private func teleportKey(_ server: Server) -> String { "server.\(server.id.uuidString).teleport-credentials.v1" }

    @MainActor
    private final class Fixture {
        private let suiteName = "KeychainManagerTeleportPasswordTests.\(UUID().uuidString)"
        private let defaults: UserDefaults
        let backing = InMemoryKeychainStoreBacking()
        let store: KeychainStore
        let offlineChanges: CredentialOfflineChangeStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            store = KeychainStore(service: KeychainManager.credentialService, backing: backing)
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
