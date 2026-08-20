import Foundation
import Testing
@testable import VVTerm

@MainActor
@Suite(.serialized)
struct KeychainManagerSyncTests {
    @Test
    func enablingSyncCopiesEverySelectedCredentialBeforeRemovingLocalCopies() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .cloudflare, authMethod: .sshKeyWithPassphrase)
        let reusableKeyID = UUID()
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        let index = try JSONEncoder().encode([
            SSHKeyEntry(id: reusableKeyID, name: "Reusable", hasPassphrase: true)
        ])
        let credentialValues: [String: Data] = [
            "server.\(server.id.uuidString).password": Data("password".utf8),
            "server.\(server.id.uuidString).sshkey": Data("private".utf8),
            "server.\(server.id.uuidString).passphrase": Data("passphrase".utf8),
            "server.\(server.id.uuidString).publickey": Data("public".utf8),
            "server.\(server.id.uuidString).cloudflare.clientid": Data("client-id".utf8),
            "server.\(server.id.uuidString).cloudflare.clientsecret": Data("client-secret".utf8),
            "server.\(server.id.uuidString).credential-binding.v1": binding,
            "vvterm.sshkeys.index": index,
            "sshkey.\(reusableKeyID.uuidString).data": Data("library-private".utf8),
            "sshkey.\(reusableKeyID.uuidString).passphrase": Data("library-passphrase".utf8)
        ]
        for (key, value) in credentialValues {
            try fixture.credentialStore.set(value, forKey: key, scope: .deviceOnly)
        }
        try fixture.credentialStore.set(
            Data("device-id".utf8),
            forKey: "vvterm.deviceId",
            scope: .deviceOnly
        )
        try fixture.oauthStore.set(
            Data("oauth-token".utf8),
            forKey: "oauth.example.com",
            scope: .deviceOnly
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        for (key, value) in credentialValues {
            #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == nil)
            let storedCloudValue = try fixture.credentialStore.get(key, scope: .iCloud)
            let cloudValue = try #require(storedCloudValue)
            if key == "vvterm.sshkeys.index" {
                #expect(
                    try JSONDecoder().decode([SSHKeyEntry].self, from: cloudValue)
                        == JSONDecoder().decode([SSHKeyEntry].self, from: value)
                )
            } else if key.hasSuffix(".credential-binding.v1") {
                #expect(
                    try JSONDecoder().decode(ServerCredentialBinding.self, from: cloudValue)
                        == JSONDecoder().decode(ServerCredentialBinding.self, from: value)
                )
            } else {
                #expect(cloudValue == value, "Cloud value mismatch for \(key)")
            }
        }
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .iCloud)
                == Data("oauth-token".utf8)
        )
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .deviceOnly) == nil
        )
        #expect(
            try fixture.credentialStore.get("vvterm.deviceId", scope: .iCloud) == nil
        )
    }

    @Test
    func disablingSyncCopiesCloudCredentialsWithoutRemovingOtherDevicesCopy() throws {
        let fixture = Fixture(syncEnabled: true)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("cloud-password".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .iCloud)
        try fixture.oauthStore.set(
            Data("oauth-token".utf8),
            forKey: "oauth.example.com",
            scope: .iCloud
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == value)
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .deviceOnly)
                == Data("oauth-token".utf8)
        )
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .iCloud)
                == Data("oauth-token".utf8)
        )
        #expect(!fixture.syncState.value)
        #expect(!fixture.offlineChanges.requiresSyncDisableCommit)
    }

    @Test
    func removingCloudCredentialsKeepsLocalCopiesAndRestoresThemWhenSyncReturns() throws {
        let fixture = Fixture(syncEnabled: true)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        let reusableKeyID = UUID()
        let sshIndexKey = "vvterm.sshkeys.index"
        let sshDataKey = "sshkey.\(reusableKeyID.uuidString).data"
        let sshIndex = try JSONEncoder().encode([
            SSHKeyEntry(id: reusableKeyID, name: "Reusable", hasPassphrase: false)
        ])
        let oauthKey = "oauth.example.com"

        try fixture.credentialStore.set(Data("password".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)
        try fixture.credentialStore.set(sshIndex, forKey: sshIndexKey, scope: .iCloud)
        try fixture.credentialStore.set(Data("private".utf8), forKey: sshDataKey, scope: .iCloud)
        try fixture.oauthStore.set(Data("token".utf8), forKey: oauthKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.removeCredentialsFromICloud()

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(sshIndexKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(sshDataKey, scope: .iCloud) == nil)
        #expect(try fixture.oauthStore.get(oauthKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == Data("password".utf8))
        #expect(try fixture.credentialStore.get(sshDataKey, scope: .deviceOnly) == Data("private".utf8))
        #expect(try fixture.oauthStore.get(oauthKey, scope: .deviceOnly) == Data("token".utf8))
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .updated)
        #expect(fixture.offlineChanges.change(for: .sshKey(reusableKeyID)) == .updated)
        #expect(fixture.offlineChanges.change(for: .oauth(oauthKey)) == .updated)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("password".utf8))
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == binding)
        #expect(try fixture.credentialStore.get(sshDataKey, scope: .iCloud) == Data("private".utf8))
        #expect(try fixture.oauthStore.get(oauthKey, scope: .iCloud) == Data("token".utf8))
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func cloudRemovalPreservesAnInterruptedOfflineDeletion() throws {
        let fixture = Fixture(syncEnabled: true)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(
            Data("password".utf8),
            forKey: passwordKey,
            scope: .iCloud
        )
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        fixture.backing.failDeletes(
            from: .deviceOnly,
            service: KeychainManager.credentialService,
            key: bindingKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.deleteRejected) {
            try fixture.manager.deleteCredentials(for: server.id)
        }
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .deleted)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .deviceOnly) == binding)

        try fixture.manager.removeCredentialsFromICloud()

        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .deleted)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)

        fixture.backing.allowDeletes(
            from: .deviceOnly,
            service: KeychainManager.credentialService,
            key: bindingKey
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .deviceOnly) == nil)
    }

    @Test
    func removingCloudCredentialsRequiresSyncToBeDisabled() throws {
        let fixture = Fixture(syncEnabled: true)

        #expect(throws: CredentialSyncError.syncMustBeDisabled) {
            try fixture.manager.removeCredentialsFromICloud()
        }
    }

    @Test
    func failedOfflineSnapshotKeepsPreferenceEnabledAndExistingDeviceValues() throws {
        let fixture = Fixture(syncEnabled: true)
        let serverID = UUID()
        let cloudKey = "server.\(serverID.uuidString).password"
        let staleKey = "server.\(UUID().uuidString).password"
        try fixture.credentialStore.set(
            Data("cloud".utf8),
            forKey: cloudKey,
            scope: .iCloud
        )
        try fixture.credentialStore.set(
            Data("stale".utf8),
            forKey: staleKey,
            scope: .deviceOnly
        )
        fixture.backing.failWrites(
            to: .deviceOnly,
            service: KeychainManager.credentialService,
            key: cloudKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        }

        #expect(fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .preparingOfflineSnapshot)
        #expect(try fixture.credentialStore.get(staleKey, scope: .deviceOnly) == Data("stale".utf8))
        #expect(try fixture.credentialStore.get(cloudKey, scope: .iCloud) == Data("cloud".utf8))
    }

    @Test
    func interruptedServerBundleCopyResumesBeforeSyncBecomesDisabled() throws {
        let fixture = Fixture(syncEnabled: true)
        let server = makeServer(
            connectionMode: .standard,
            authMethod: .sshKeyWithPassphrase
        )
        let prefix = "server.\(server.id.uuidString)"
        let values: [String: Data] = [
            "\(prefix).credential-binding.v1": try JSONEncoder().encode(
                ServerCredentialBinding(server: server)
            ),
            "\(prefix).passphrase": Data("passphrase".utf8),
            "\(prefix).publickey": Data("public".utf8),
            "\(prefix).sshkey": Data("private".utf8)
        ]
        for (key, value) in values {
            try fixture.credentialStore.set(value, forKey: key, scope: .iCloud)
        }
        let rejectedKey = "\(prefix).publickey"
        fixture.backing.failWrites(
            to: .deviceOnly,
            service: KeychainManager.credentialService,
            key: rejectedKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        }
        #expect(fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .preparingOfflineSnapshot)
        #expect(try fixture.credentialStore.get("\(prefix).passphrase", scope: .deviceOnly) != nil)
        #expect(try fixture.credentialStore.get(rejectedKey, scope: .deviceOnly) == nil)

        fixture.backing.allowWrites(
            to: .deviceOnly,
            service: KeychainManager.credentialService,
            key: rejectedKey
        )
        _ = fixture.makeRelaunchedManager(performsInitialMigration: true)

        #expect(!fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .remoteChanges)
        #expect(!fixture.offlineChanges.requiresSyncDisableCommit)
        for (key, value) in values {
            #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
            #expect(try fixture.credentialStore.get(key, scope: .iCloud) == value)
        }

        let relaunchedManager = fixture.makeRelaunchedManager()
        try relaunchedManager.synchronizeCredentialStorage(isEnabled: true)
        #expect(fixture.syncState.value)
        for (key, value) in values {
            #expect(try fixture.credentialStore.get(key, scope: .iCloud) == value)
        }
    }

    @Test
    func preparingSnapshotResumesEvenWhenPersistedPreferenceIsAlreadyDisabled() throws {
        let fixture = Fixture(syncEnabled: true)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("cloud".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .iCloud)
        fixture.backing.failWrites(
            to: .deviceOnly,
            service: KeychainManager.credentialService,
            key: key
        )
        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        }
        fixture.syncState.value = false
        fixture.backing.allowWrites(
            to: .deviceOnly,
            service: KeychainManager.credentialService,
            key: key
        )

        _ = fixture.makeRelaunchedManager(performsInitialMigration: true)

        #expect(!fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .remoteChanges)
        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == value)
    }

    @Test
    func failedEnableCopyPreservesTheLocalCredential() throws {
        let fixture = Fixture(syncEnabled: false)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("local-password".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .deviceOnly)
        fixture.backing.failWrites(to: .iCloud)

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
        }
        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == nil)
    }

    @Test
    func failedEnableVerificationPreservesTheDeviceOnlyCredential() throws {
        let fixture = Fixture(syncEnabled: false)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("local-password".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .deviceOnly)
        fixture.backing.corruptReads(
            from: .iCloud,
            service: KeychainManager.credentialService,
            key: key
        )

        do {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
            Issue.record("Expected copy verification to fail")
        } catch KeychainError.copyVerificationFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
    }

    @Test
    func failedSecondRemoteUnitKeepsEveryDeviceSnapshot() throws {
        let fixture = Fixture(syncEnabled: false)
        let serverID = UUID()
        let credentialKey = "server.\(serverID.uuidString).password"
        let oauthKey = "oauth.example.com"
        let credential = Data("local-password".utf8)
        let oauth = Data("local-oauth".utf8)
        try fixture.credentialStore.set(
            credential,
            forKey: credentialKey,
            scope: .deviceOnly
        )
        try fixture.oauthStore.set(oauth, forKey: oauthKey, scope: .deviceOnly)
        try fixture.offlineChanges.beginOfflineTracking(
            changes: [
                .server(serverID): .updated,
                .oauth(oauthKey): .updated
            ]
        )
        fixture.backing.failWrites(
            to: .iCloud,
            service: KeychainManager.credentialService,
            key: credentialKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
        }

        #expect(try fixture.credentialStore.get(credentialKey, scope: .deviceOnly) == credential)
        #expect(try fixture.credentialStore.get(credentialKey, scope: .iCloud) == nil)
        #expect(try fixture.oauthStore.get(oauthKey, scope: .deviceOnly) == oauth)
        #expect(try fixture.oauthStore.get(oauthKey, scope: .iCloud) == oauth)
        #expect(fixture.offlineChanges.reconciliationPhase == .remoteChanges)
    }

    @Test
    func repeatedDisableKeepsTheOriginalOfflineSnapshot() throws {
        let fixture = Fixture(syncEnabled: false)
        let key = "server.\(UUID().uuidString).password"
        try fixture.credentialStore.set(Data("P1".utf8), forKey: key, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.credentialStore.set(Data("P2".utf8), forKey: key, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == Data("P1".utf8))
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == Data("P2".utf8))
        #expect(fixture.offlineChanges.reconciliationPhase == .remoteChanges)
    }

    @Test
    func localCleanupFailureStaysRecoverableAfterRemoteCommit() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: server)),
            forKey: bindingKey,
            scope: .iCloud
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "P2"),
            for: server
        )
        fixture.backing.failDeletes(
            from: .deviceOnly,
            service: KeychainManager.credentialService,
            key: passwordKey
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .localCleanup)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P2".utf8))
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == Data("P2".utf8))

        fixture.backing.allowDeletes(
            from: .deviceOnly,
            service: KeychainManager.credentialService,
            key: passwordKey
        )
        let relaunchedManager = fixture.makeRelaunchedManager()
        try relaunchedManager.synchronizeCredentialStorage(isEnabled: true)

        #expect(fixture.offlineChanges.reconciliationPhase == nil)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P2".utf8))
    }

    @Test
    func pendingLocalCleanupBuildsNewSnapshotBeforeOfflineEdits() async throws {
        let fixture = Fixture(syncEnabled: false)
        let tokenKey = "oauth.example"
        try fixture.oauthStore.setString("P1", forKey: tokenKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        let adapter = CloudflareTokenStoreAdapter(
            store: fixture.oauthStore,
            isSyncEnabled: { false },
            offlineChanges: fixture.offlineChanges
        )
        try await adapter.writeToken("P2", for: "example")
        fixture.backing.failDeletes(
            from: .deviceOnly,
            service: KeychainManager.cloudflareTokenService,
            key: tokenKey
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
        #expect(fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .localCleanup)

        fixture.backing.allowDeletes(
            from: .deviceOnly,
            service: KeychainManager.cloudflareTokenService,
            key: tokenKey
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        #expect(!fixture.syncState.value)
        #expect(fixture.offlineChanges.reconciliationPhase == .remoteChanges)
        try await adapter.writeToken("P3", for: "example")
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.oauthStore.getString(tokenKey, scope: .iCloud) == "P3")
        #expect(try fixture.oauthStore.getString(tokenKey, scope: .deviceOnly) == nil)
        #expect(fixture.offlineChanges.reconciliationPhase == nil)
    }

    @Test
    func initialMigrationPersistsEveryDeviceUnitAsUpdatedBeforeRemoteCopy() throws {
        let fixture = Fixture(syncEnabled: false)
        let serverID = UUID()
        let passwordKey = "server.\(serverID.uuidString).password"
        let oauthKey = "oauth.example"
        try fixture.credentialStore.set(
            Data("password".utf8),
            forKey: passwordKey,
            scope: .deviceOnly
        )
        try fixture.oauthStore.set(
            Data("token".utf8),
            forKey: oauthKey,
            scope: .deviceOnly
        )
        fixture.backing.failWrites(to: .iCloud)

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
        }

        let relaunchedStore = CredentialOfflineChangeStore(defaults: fixture.defaults)
        #expect(relaunchedStore.change(for: .server(serverID)) == .updated)
        #expect(relaunchedStore.change(for: .oauth(oauthKey)) == .updated)
        #expect(relaunchedStore.reconciliationPhase == .remoteChanges)
    }

    @Test
    func failedOfflineOAuthMarkerWriteKeepsLiveValueAndResumesFromStaging() async throws {
        let suiteName = "KeychainManagerSyncTests.rejecting.\(UUID().uuidString)"
        let defaults = CredentialStateWriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = Fixture(syncEnabled: false, defaults: defaults)
        let tokenKey = "oauth.example"
        try fixture.oauthStore.setString("old", forKey: tokenKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        let adapter = CloudflareTokenStoreAdapter(
            store: fixture.oauthStore,
            isSyncEnabled: { false },
            offlineChanges: fixture.offlineChanges
        )

        defaults.rejectCredentialStateWrites = true
        do {
            try await adapter.writeToken("new", for: "example")
            Issue.record("Expected the durable change marker write to fail")
        } catch CredentialOfflineChangeStoreError.persistenceFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try fixture.oauthStore.getString(tokenKey, scope: .deviceOnly) == "old")
        #expect(try fixture.oauthStore.getString(tokenKey, scope: .iCloud) == "old")
        #expect(fixture.offlineChanges.change(for: .oauth(tokenKey)) == .unchanged)

        defaults.rejectCredentialStateWrites = false
        let relaunchedManager = KeychainManager(
            store: fixture.credentialStore,
            cloudflareTokenStore: fixture.oauthStore,
            isSyncEnabled: { true },
            offlineChanges: CredentialOfflineChangeStore(defaults: defaults)
        )
        try relaunchedManager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.oauthStore.getString(tokenKey, scope: .iCloud) == "new")
        #expect(try fixture.oauthStore.getString(tokenKey, scope: .deviceOnly) == nil)
    }

    @Test
    func launchResumesPendingSSHKeyWriteWhileSyncRemainsDisabled() throws {
        let suiteName = "KeychainManagerSyncTests.ssh-write.\(UUID().uuidString)"
        let defaults = CredentialStateWriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = Fixture(syncEnabled: true, defaults: defaults)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        defaults.rejectCredentialStateWrites = true
        do {
            _ = try fixture.manager.storeSSHKeyEntry(
                name: "Interrupted",
                privateKey: Data("private".utf8),
                passphrase: "secret"
            )
            Issue.record("Expected the durable change marker write to fail")
        } catch CredentialOfflineChangeStoreError.persistenceFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(fixture.offlineChanges.reconciliationPhase == .remoteChanges)

        defaults.rejectCredentialStateWrites = false
        _ = fixture.makeRelaunchedManager(performsInitialMigration: true)

        #expect(!fixture.syncState.value)
        let entries = try loadSSHLibrary(scope: .deviceOnly, from: fixture.credentialStore)
        let entry = try #require(entries.first)
        #expect(entry.name == "Interrupted")
        #expect(
            try fixture.credentialStore.get(
                "sshkey.\(entry.id.uuidString).data",
                scope: .deviceOnly
            ) == Data("private".utf8)
        )
        #expect(fixture.offlineChanges.change(for: .sshKey(entry.id)) == .updated)
        #expect(try fixture.credentialStore.keys(in: .iCloud).isEmpty)
    }

    @Test
    func launchResumesTrackedReconciliationAfterMigrationCompleted() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: server)),
            forKey: bindingKey,
            scope: .iCloud
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "P2"),
            for: server
        )
        let previousMigrationFlag = UserDefaults.standard.object(
            forKey: KeychainManager.iCloudMigrationKey
        )
        UserDefaults.standard.set(true, forKey: KeychainManager.iCloudMigrationKey)
        defer {
            if let previousMigrationFlag {
                UserDefaults.standard.set(previousMigrationFlag, forKey: KeychainManager.iCloudMigrationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: KeychainManager.iCloudMigrationKey)
            }
        }

        _ = KeychainManager(
            store: fixture.credentialStore,
            cloudflareTokenStore: fixture.oauthStore,
            isSyncEnabled: { true },
            offlineChanges: fixture.offlineChanges,
            performsInitialMigration: true
        )

        #expect(fixture.offlineChanges.reconciliationPhase == nil)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P2".utf8))
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func disabledSyncDoesNotReadTheCopyOwnedByOtherDevices() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let prefix = "server.\(server.id.uuidString)"
        try fixture.credentialStore.set(
            Data("cloud-password".utf8),
            forKey: "\(prefix).password",
            scope: .iCloud
        )
        try fixture.credentialStore.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: server)),
            forKey: "\(prefix).credential-binding.v1",
            scope: .iCloud
        )

        let credentials = try fixture.manager.getCredentials(for: server)

        #expect(credentials.password == nil)
        #expect(!(try fixture.manager.hasCredentials(for: server)))
    }

    @Test
    func unchangedOfflineSnapshotDoesNotOverwriteNewerCloudCredentials() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.credentialStore.set(Data("P2".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P2".utf8))
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func explicitOfflineUpdateReplacesCloudCredentialBundle() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.credentialStore.set(Data("P2".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "P3"),
            for: server
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P3".utf8))
        let storedCloudBinding = try fixture.credentialStore.get(bindingKey, scope: .iCloud)
        let cloudBindingData = try #require(storedCloudBinding)
        #expect(
            try JSONDecoder().decode(ServerCredentialBinding.self, from: cloudBindingData)
                == ServerCredentialBinding(server: server)
        )
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func explicitOfflineDeletionCannotReturnWhenSyncIsEnabled() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.deleteCredentials(for: server.id)
        try fixture.credentialStore.set(Data("stale".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func offlineSSHKeyRenameKeepsAKeyAddedByAnotherDevice() throws {
        let fixture = Fixture(syncEnabled: false)
        let keyX = SSHKeyEntry(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Key X",
            hasPassphrase: false
        )
        let keyY = SSHKeyEntry(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Key Y",
            hasPassphrase: false
        )
        try storeSSHLibrary(
            entries: [keyX],
            privateKeys: [keyX.id: Data("private-x".utf8)],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        try storeSSHLibrary(
            entries: [keyX, keyY],
            privateKeys: [
                keyX.id: Data("private-x".utf8),
                keyY.id: Data("private-y".utf8)
            ],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.updateStoredSSHKeyName(keyX.id, name: "Renamed X")
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        let cloudEntries = try loadSSHLibrary(scope: .iCloud, from: fixture.credentialStore)
        #expect(cloudEntries.first(where: { $0.id == keyX.id })?.name == "Renamed X")
        #expect(cloudEntries.contains(where: { $0.id == keyY.id }))
        #expect(
            try fixture.credentialStore.get(
                "sshkey.\(keyY.id.uuidString).data",
                scope: .iCloud
            ) == Data("private-y".utf8)
        )
    }

    @Test
    func offlineSSHKeyDeletionRemovesOnlyThatKey() throws {
        let fixture = Fixture(syncEnabled: false)
        let keyX = SSHKeyEntry(id: UUID(), name: "Key X", hasPassphrase: false)
        let keyY = SSHKeyEntry(id: UUID(), name: "Key Y", hasPassphrase: false)
        try storeSSHLibrary(
            entries: [keyX, keyY],
            privateKeys: [
                keyX.id: Data("private-x".utf8),
                keyY.id: Data("private-y".utf8)
            ],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        try fixture.manager.deleteStoredSSHKey(keyX.id)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        let cloudEntries = try loadSSHLibrary(scope: .iCloud, from: fixture.credentialStore)
        #expect(!cloudEntries.contains(where: { $0.id == keyX.id }))
        #expect(cloudEntries.contains(where: { $0.id == keyY.id }))
        #expect(
            try fixture.credentialStore.get(
                "sshkey.\(keyY.id.uuidString).data",
                scope: .iCloud
            ) == Data("private-y".utf8)
        )
    }

    @Test
    func newOfflineSSHKeyMergesIntoTheCurrentCloudIndex() throws {
        let fixture = Fixture(syncEnabled: false)
        let cloudKey = SSHKeyEntry(id: UUID(), name: "Cloud key", hasPassphrase: false)
        try storeSSHLibrary(
            entries: [cloudKey],
            privateKeys: [cloudKey.id: Data("cloud-private".utf8)],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        let localKey = try fixture.manager.storeSSHKeyEntry(
            name: "Local key",
            privateKey: Data("local-private".utf8),
            passphrase: nil
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        let cloudEntries = try loadSSHLibrary(scope: .iCloud, from: fixture.credentialStore)
        #expect(cloudEntries.contains(where: { $0.id == cloudKey.id }))
        #expect(cloudEntries.contains(where: { $0.id == localKey.id }))
    }

    @Test
    func newerCloudSSHKeyMetadataWinsOverAnOlderOfflineRename() throws {
        let fixture = Fixture(syncEnabled: false)
        let keyID = UUID()
        let original = SSHKeyEntry(
            id: keyID,
            name: "Original",
            hasPassphrase: false,
            createdAt: .distantPast
        )
        try storeSSHLibrary(
            entries: [original],
            privateKeys: [keyID: Data("private".utf8)],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.updateStoredSSHKeyName(keyID, name: "Offline rename")

        let newerCloudEntry = SSHKeyEntry(
            id: keyID,
            name: "Newer cloud name",
            hasPassphrase: false,
            createdAt: .distantPast,
            updatedAt: .distantFuture
        )
        try storeSSHLibrary(
            entries: [newerCloudEntry],
            privateKeys: [keyID: Data("newer-private".utf8)],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        let cloudEntries = try loadSSHLibrary(scope: .iCloud, from: fixture.credentialStore)
        #expect(cloudEntries.first?.name == "Newer cloud name")
        #expect(
            try fixture.credentialStore.get(
                "sshkey.\(keyID.uuidString).data",
                scope: .iCloud
            ) == Data("newer-private".utf8)
        )
    }

    @Test
    func newerCloudSSHKeyUpdateWinsOverAnOlderOfflineDeletion() throws {
        let fixture = Fixture(syncEnabled: false)
        let keyID = UUID()
        let original = SSHKeyEntry(
            id: keyID,
            name: "Original",
            hasPassphrase: false,
            createdAt: .distantPast
        )
        try storeSSHLibrary(
            entries: [original],
            privateKeys: [keyID: Data("private".utf8)],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.deleteStoredSSHKey(keyID)

        let newerCloudEntry = SSHKeyEntry(
            id: keyID,
            name: "Restored remotely",
            hasPassphrase: false,
            createdAt: .distantPast,
            updatedAt: .distantFuture
        )
        try storeSSHLibrary(
            entries: [newerCloudEntry],
            privateKeys: [keyID: Data("newer-private".utf8)],
            scope: .iCloud,
            in: fixture.credentialStore
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        let cloudEntries = try loadSSHLibrary(scope: .iCloud, from: fixture.credentialStore)
        #expect(cloudEntries.first?.name == "Restored remotely")
        #expect(
            try fixture.credentialStore.get(
                "sshkey.\(keyID.uuidString).data",
                scope: .iCloud
            ) == Data("newer-private".utf8)
        )
    }

    @Test
    func failedOfflineDeletionRemainsPendingUntilCleanupSucceeds() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        fixture.backing.failDeletes(
            from: .iCloud,
            service: KeychainManager.credentialService,
            key: passwordKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.deleteRejected) {
            try fixture.manager.deleteCredentials(for: server.id)
        }
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .deleted)

        fixture.backing.allowDeletes(
            from: .iCloud,
            service: KeychainManager.credentialService,
            key: passwordKey
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == nil)
        #expect(!fixture.offlineChanges.isTrackingOfflineChanges)
    }

    @Test
    func synchronizedWritesIncludeBindingsAndAllServerCredentialFields() throws {
        let fixture = Fixture(syncEnabled: true)
        let passwordServer = makeServer(
            connectionMode: .standard,
            authMethod: .password
        )
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: passwordServer.id, password: "password"),
            for: passwordServer
        )
        let server = makeServer(
            connectionMode: .cloudflare,
            authMethod: .sshKeyWithPassphrase
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            privateKey: Data("private".utf8),
            publicKey: Data("public".utf8),
            passphrase: "passphrase",
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        try fixture.manager.storeCredentials(credentials, for: server)
        let reusableKey = try fixture.manager.storeSSHKeyEntry(
            name: "Reusable",
            privateKey: Data("library-private".utf8),
            passphrase: "library-passphrase"
        )

        let prefix = "server.\(server.id.uuidString)"
        for key in [
            "server.\(passwordServer.id.uuidString).password",
            "server.\(passwordServer.id.uuidString).credential-binding.v1",
            "\(prefix).sshkey",
            "\(prefix).passphrase",
            "\(prefix).publickey",
            "\(prefix).cloudflare.clientid",
            "\(prefix).cloudflare.clientsecret",
            "\(prefix).credential-binding.v1",
            "vvterm.sshkeys.index",
            "sshkey.\(reusableKey.id.uuidString).data",
            "sshkey.\(reusableKey.id.uuidString).passphrase"
        ] {
            #expect(try fixture.credentialStore.contains(key, scope: .iCloud))
            #expect(!(try fixture.credentialStore.contains(key, scope: .deviceOnly)))
        }
    }

    @Test
    func loadingCredentialsAutomaticallyRebindsThemToTheCurrentServerEndpoint() throws {
        let fixture = Fixture(syncEnabled: true)
        let originalServer = makeServer(connectionMode: .standard, authMethod: .password)
        var server = originalServer
        server.host = "changed.example.com"
        let prefix = "server.\(server.id.uuidString)"
        try fixture.credentialStore.set(
            Data("cloud-password".utf8),
            forKey: "\(prefix).password",
            scope: .iCloud
        )
        try fixture.credentialStore.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: originalServer)),
            forKey: "\(prefix).credential-binding.v1",
            scope: .iCloud
        )

        let credentials = try fixture.manager.getCredentials(for: server)

        #expect(credentials.password == "cloud-password")
        #expect(credentials.credentialBinding == ServerCredentialBinding(server: server))
        let storedBindingData = try fixture.credentialStore.get(
            "\(prefix).credential-binding.v1",
            scope: .iCloud
        )
        let boundData = try #require(storedBindingData)
        #expect(
            try JSONDecoder().decode(ServerCredentialBinding.self, from: boundData)
                == ServerCredentialBinding(server: server)
        )
    }

    @Test
    func differentServerUUIDDoesNotInheritCredentialsFromAnEquivalentServer() throws {
        let fixture = Fixture(syncEnabled: true)
        let original = makeServer(connectionMode: .standard, authMethod: .password)
        let duplicate = makeServer(connectionMode: .standard, authMethod: .password)
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: original.id, password: "original-password"),
            for: original
        )

        let duplicateCredentials = try fixture.manager.getCredentials(for: duplicate)

        #expect(original.id != duplicate.id)
        #expect(duplicateCredentials.password == nil)
        #expect(!(try fixture.manager.hasCredentials(for: duplicate)))
    }

    @Test
    func oauthTokenWritesUseTheSelectedSyncScope() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(
            service: KeychainManager.cloudflareTokenService,
            backing: backing
        )
        let syncedAdapter = CloudflareTokenStoreAdapter(
            store: store,
            isSyncEnabled: { true }
        )
        try await syncedAdapter.writeToken("cloud-token", for: "cloud")

        let localAdapter = CloudflareTokenStoreAdapter(
            store: store,
            isSyncEnabled: { false }
        )
        try await localAdapter.writeToken("local-token", for: "local")

        #expect(try store.getString("oauth.cloud", scope: .iCloud) == "cloud-token")
        #expect(
            try store.getString("oauth.local", scope: .deviceOnly) == "local-token"
        )
    }

    @Test
    func offlineOAuthDeletionRemainsDeletedAfterEnable() async throws {
        let fixture = Fixture(syncEnabled: false)
        let adapter = CloudflareTokenStoreAdapter(
            store: fixture.oauthStore,
            isSyncEnabled: { false },
            offlineChanges: fixture.offlineChanges
        )
        try fixture.oauthStore.setString(
            "cloud-token",
            forKey: "oauth.example",
            scope: .iCloud
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        try await adapter.removeToken(for: "example")
        try fixture.oauthStore.setString(
            "stale-token",
            forKey: "oauth.example",
            scope: .iCloud
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.oauthStore.getString("oauth.example", scope: .iCloud) == nil)
        #expect(try fixture.oauthStore.getString("oauth.example", scope: .deviceOnly) == nil)
    }

    @MainActor
    private final class Fixture {
        let backing = InMemoryKeychainStoreBacking()
        let credentialStore: KeychainStore
        let oauthStore: KeychainStore
        let offlineChanges: CredentialOfflineChangeStore
        let manager: KeychainManager
        let defaults: UserDefaults
        let syncState: KeychainSyncEnabledState

        init(syncEnabled: Bool, defaults providedDefaults: UserDefaults? = nil) {
            if let providedDefaults {
                defaults = providedDefaults
            } else {
                let suiteName = "KeychainManagerSyncTests.\(UUID().uuidString)"
                defaults = UserDefaults(suiteName: suiteName)!
                defaults.removePersistentDomain(forName: suiteName)
            }
            offlineChanges = CredentialOfflineChangeStore(defaults: defaults)
            syncState = KeychainSyncEnabledState(syncEnabled)
            credentialStore = KeychainStore(
                service: KeychainManager.credentialService,
                backing: backing
            )
            oauthStore = KeychainStore(
                service: KeychainManager.cloudflareTokenService,
                backing: backing
            )
            manager = KeychainManager(
                store: credentialStore,
                cloudflareTokenStore: oauthStore,
                isSyncEnabled: { [syncState] in syncState.value },
                persistSyncEnabled: { [syncState] in syncState.value = $0 },
                offlineChanges: offlineChanges
            )
        }

        func makeRelaunchedManager(
            performsInitialMigration: Bool = false
        ) -> KeychainManager {
            KeychainManager(
                store: credentialStore,
                cloudflareTokenStore: oauthStore,
                isSyncEnabled: { [syncState] in syncState.value },
                persistSyncEnabled: { [syncState] in syncState.value = $0 },
                offlineChanges: CredentialOfflineChangeStore(defaults: defaults),
                performsInitialMigration: performsInitialMigration
            )
        }
    }

    private func makeServer(
        connectionMode: SSHConnectionMode,
        authMethod: AuthMethod
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 22,
            username: "root",
            connectionMode: connectionMode,
            authMethod: authMethod,
            cloudflareAccessMode: connectionMode == .cloudflare ? .serviceToken : nil,
            cloudflareTeamDomainOverride: connectionMode == .cloudflare
                ? "team.cloudflareaccess.com"
                : nil,
            cloudflareAppDomainOverride: connectionMode == .cloudflare
                ? "app.example.com"
                : nil
        )
    }

    private func storeSSHLibrary(
        entries: [SSHKeyEntry],
        privateKeys: [UUID: Data],
        scope: KeychainStorageScope,
        in store: KeychainStore
    ) throws {
        try store.set(
            try JSONEncoder().encode(entries),
            forKey: "vvterm.sshkeys.index",
            scope: scope
        )
        for (id, privateKey) in privateKeys {
            try store.set(
                privateKey,
                forKey: "sshkey.\(id.uuidString).data",
                scope: scope
            )
        }
    }

    private func loadSSHLibrary(
        scope: KeychainStorageScope,
        from store: KeychainStore
    ) throws -> [SSHKeyEntry] {
        let storedData = try store.get("vvterm.sshkeys.index", scope: scope)
        let data = try #require(storedData)
        return try JSONDecoder().decode([SSHKeyEntry].self, from: data)
    }
}

private final class KeychainSyncEnabledState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class CredentialStateWriteRejectingUserDefaults: UserDefaults {
    var rejectCredentialStateWrites = false

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectCredentialStateWrites
                || defaultName != "vvterm.keychain.offlineReconciliation.v3" else {
            return
        }
        super.set(value, forKey: defaultName)
    }
}
