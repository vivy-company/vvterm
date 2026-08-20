import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerLocalStoreTests {
    @Test
    func missingDataIsDifferentFromAnEmptyCollection() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = ServerLocalStore(defaults: defaults)

        guard case .missing = store.loadServers() else {
            Issue.record("Expected missing server data")
            return
        }

        try store.storeServers([])
        guard case .loaded(let servers) = store.loadServers() else {
            Issue.record("Expected a stored empty server collection")
            return
        }
        #expect(servers.isEmpty)
    }

    @Test
    func corruptDataIsQuarantinedBeforeAReplacementWrite() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let corruptData = Data("not-json".utf8)
        defaults.set(corruptData, forKey: ServerLocalStore.serversStorageKey)
        let store = ServerLocalStore(defaults: defaults)

        guard case .unreadable(let issue) = store.loadServers() else {
            Issue.record("Expected unreadable server data")
            return
        }

        #expect(defaults.data(forKey: issue.quarantineKey) == corruptData)
        try store.storeServers([])
        #expect(defaults.data(forKey: issue.quarantineKey) == corruptData)
    }

    @Test
    func incompatibleWorkspaceDataIsQuarantined() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let incompatibleData = try JSONSerialization.data(
            withJSONObject: [["id": UUID().uuidString, "unknown": true]]
        )
        defaults.set(incompatibleData, forKey: ServerLocalStore.workspacesStorageKey)
        let store = ServerLocalStore(defaults: defaults)

        guard case .unreadable(let issue) = store.loadWorkspaces() else {
            Issue.record("Expected incompatible workspace data")
            return
        }

        #expect(issue.collection == .workspaces)
        #expect(defaults.data(forKey: issue.quarantineKey) == incompatibleData)
    }

    @Test
    func repeatedDecodeFailuresKeepTheFirstQuarantineCopy() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstData = Data("first-corrupt-copy".utf8)
        let secondData = Data("second-corrupt-copy".utf8)
        defaults.set(firstData, forKey: ServerLocalStore.serversStorageKey)
        let store = ServerLocalStore(defaults: defaults)

        guard case .unreadable(let firstIssue) = store.loadServers() else {
            Issue.record("Expected the first decode failure")
            return
        }
        defaults.set(secondData, forKey: ServerLocalStore.serversStorageKey)
        guard case .unreadable = store.loadServers() else {
            Issue.record("Expected the second decode failure")
            return
        }

        #expect(defaults.data(forKey: firstIssue.quarantineKey) == firstData)
    }

    @Test
    func repositoryPersistsLoadsAndClearsOneCollectionSnapshot() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = ServerLocalStore(defaults: defaults)
        let workspace = Workspace(name: "Workspace", order: 0)
        let server = Server(
            workspaceId: workspace.id,
            name: "Server",
            host: "server.example.test",
            username: "root"
        )

        try store.persist(servers: [server], workspaces: [workspace])
        let snapshot = store.loadSnapshot()

        guard case .loaded(let loadedServers) = snapshot.servers,
              case .loaded(let loadedWorkspaces) = snapshot.workspaces else {
            Issue.record("Expected one complete local repository snapshot")
            return
        }
        #expect(loadedServers == [server])
        #expect(loadedWorkspaces == [workspace])

        try store.clearServerData()
        guard case .missing = store.loadSnapshot().servers,
              case .missing = store.loadSnapshot().workspaces else {
            Issue.record("Expected cleared repository collections")
            return
        }
    }

    @Test
    func normalPersistenceIsRejectedWhileServerDataJournalExists() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = ServerLocalStore(defaults: defaults)
        let workspace = Workspace(name: "Workspace", order: 0)
        let server = Server(
            workspaceId: workspace.id,
            name: "Server",
            host: "server.example.test",
            username: "root"
        )
        let plan = ServerDataMutationPlan(
            id: UUID(),
            previousServers: [server],
            previousWorkspaces: [workspace],
            resultingServers: [server],
            resultingWorkspaces: [workspace],
            pendingMutation: ServerPendingMutation(
                id: UUID(),
                payload: .serverUpsert(server),
                createdAt: .distantPast
            ),
            credentialAction: .delete([server])
        )
        try store.storeServerDataMutationJournal(
            ServerDataMutationJournal(plan: plan)
        )

        #expect(throws: ServerLocalStoreError.serverDataMutationPending) {
            try store.persist(servers: [], workspaces: [])
        }
        #expect(throws: ServerLocalStoreError.serverDataMutationPending) {
            try store.clearServerData()
        }

        try store.materializeServerDataMutation(plan)
        guard case .loaded(let servers) = store.loadServers() else {
            Issue.record("Expected transaction state")
            return
        }
        #expect(servers == plan.previousServers)
    }

    @Test
    func ambiguousCloudRecoveryBackupSurvivesRestartAndKeepsFirstSnapshot() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let workspace = Workspace(name: "Original", order: 0)
        let server = Server(
            workspaceId: workspace.id,
            name: "Server",
            host: "server.example.test",
            username: "root"
        )
        let backup = AmbiguousCloudRecoveryBackup(
            servers: [server],
            workspaces: [workspace]
        )
        let store = ServerLocalStore(defaults: defaults)

        try store.storeAmbiguousCloudRecoveryBackup(backup)
        try store.storeAmbiguousCloudRecoveryBackup(
            AmbiguousCloudRecoveryBackup(
                servers: [],
                workspaces: []
            )
        )

        let restartedStore = ServerLocalStore(defaults: defaults)
        #expect(try restartedStore.loadAmbiguousCloudRecoveryBackup() == backup)

        try restartedStore.clearAmbiguousCloudRecoveryBackup()
        #expect(try store.loadAmbiguousCloudRecoveryBackup() == nil)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "ServerLocalStoreTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
