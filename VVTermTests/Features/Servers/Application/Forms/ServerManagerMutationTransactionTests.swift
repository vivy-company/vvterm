import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerMutationTransactionTests {
    @Test
    func createQueueFailureKeepsCommittedMetadataAndCredentialsForRecovery() async throws {
        let workspace = makeWorkspace()
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(local: local, credentials: credentials, sync: sync)
        let useCase = ServerSaveUseCase(mutations: manager)
        let server = makeServer(workspaceID: workspace.id)
        var newCredentials = ServerCredentials(serverId: server.id)
        newCredentials.password = "new-password"

        await #expect(throws: VVTermError.self) {
            try await useCase.execute(
                .create(server),
                credentials: newCredentials,
                hasProAccess: true
            )
        }

        #expect(manager.servers.map(\.id) == [server.id])
        #expect(manager.servers.first?.host == server.host)
        #expect(credentials.values[server.id]?.password == "new-password")
        let pending = try #require(local.serverMutationJournal)
        #expect(pending.phase == .enqueueing)

        sync.enqueueError = nil
        let resumed = try #require(
            try manager.stateStore.makeServerDataMutationTransaction(
                mutationQueue: sync,
                credentials: credentials
            ).resumePending()
        )

        #expect(resumed.phase == .complete)
        #expect(local.servers == [resumed.plan.resultingServers[0]])
        #expect(credentials.values[server.id]?.password == "new-password")
        #expect(sync.enqueuedServerMutations.count == 1)
    }

    @Test
    func editQueueFailureKeepsNewMetadataWithNewCredentials() async throws {
        let workspace = makeWorkspace()
        let storedServer = makeServer(workspaceID: workspace.id, host: "old.example.test")
        var editedServer = storedServer
        editedServer.host = "new.example.test"
        let local = ServerLocalRepositoryFake(servers: [storedServer], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        var oldCredentials = ServerCredentials(serverId: storedServer.id)
        oldCredentials.password = "old-password"
        credentials.values[storedServer.id] = oldCredentials
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(local: local, credentials: credentials, sync: sync)
        let useCase = ServerSaveUseCase(mutations: manager)
        var newCredentials = ServerCredentials(serverId: editedServer.id)
        newCredentials.password = "new-password"

        await #expect(throws: VVTermError.self) {
            try await useCase.execute(
                .update(editedServer),
                credentials: newCredentials,
                hasProAccess: true
            )
        }

        #expect(manager.servers.first?.host == "new.example.test")
        #expect(credentials.values[storedServer.id]?.password == "new-password")

        sync.enqueueError = nil
        let resumed = try #require(
            try manager.stateStore.makeServerDataMutationTransaction(
                mutationQueue: sync,
                credentials: credentials
            ).resumePending()
        )

        #expect(resumed.phase == .complete)
        #expect(resumed.plan.resultingServers.first?.host == "new.example.test")
        #expect(credentials.values[storedServer.id]?.password == "new-password")
    }

    @Test
    func deleteQueueFailureKeepsCompletedLocalDeletionForRecovery() async throws {
        let workspace = makeWorkspace()
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        credentials.values[server.id] = ServerCredentials(serverId: server.id)
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(local: local, credentials: credentials, sync: sync)

        await #expect(throws: VVTermError.self) {
            try await manager.deleteServer(server)
        }

        #expect(manager.servers.isEmpty)
        #expect(credentials.values[server.id] == nil)
        #expect(local.serverMutationJournal?.phase == .enqueueing)

        sync.enqueueError = nil
        let resumed = try #require(
            try manager.stateStore.makeServerDataMutationTransaction(
                mutationQueue: sync,
                credentials: credentials
            ).resumePending()
        )

        #expect(resumed.phase == .complete)
        #expect(local.servers.isEmpty)
        #expect(credentials.values[server.id] == nil)
    }

    @Test
    func deleteCredentialFailureLeavesRecoverableJournalBeforeQueueCommit() async {
        let workspace = makeWorkspace()
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        credentials.values[server.id] = ServerCredentials(serverId: server.id)
        credentials.deleteError = TestTransactionError.persistence
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(local: local, credentials: credentials, sync: sync)

        await #expect(throws: VVTermError.self) {
            try await manager.deleteServer(server)
        }

        #expect(manager.servers == [server])
        #expect(credentials.values[server.id] != nil)
        #expect(local.serverMutationJournal?.phase == .finalizingCredentials)
        #expect(sync.enqueuedServerMutations.isEmpty)
    }

    @Test
    func pendingServerSaveBlocksWorkspacePersistenceUntilRecovery() async throws {
        let workspace = makeWorkspace()
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        credentials.values[server.id] = ServerCredentials(serverId: server.id)
        credentials.commitError = TestTransactionError.persistence
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(local: local, credentials: credentials, sync: sync)
        var editedServer = server
        editedServer.host = "new.example.test"

        await #expect(throws: VVTermError.self) {
            try await manager.apply(
                .update(editedServer),
                credentials: ServerCredentials(serverId: server.id)
            )
        }
        var editedWorkspace = workspace
        editedWorkspace.name = "Changed"
        await #expect(throws: ServerDataMutationTransactionError.self) {
            try await manager.updateWorkspace(editedWorkspace)
        }

        #expect(local.workspaces == [workspace])
        #expect(sync.enqueuedServerMutations.isEmpty)
        credentials.commitError = nil
        let resumed = try #require(
            try manager.stateStore.makeServerDataMutationTransaction(
                mutationQueue: sync,
                credentials: credentials
            ).resumePending()
        )
        #expect(resumed.phase == .complete)
        #expect(local.servers.first?.host == "new.example.test")
        #expect(local.workspaces == [workspace])
    }

    @Test
    func pendingServerSaveBlocksLastConnectedAndAuthoritativeResync() async throws {
        let workspace = makeWorkspace()
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        credentials.commitError = TestTransactionError.persistence
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(local: local, credentials: credentials, sync: sync)

        await #expect(throws: VVTermError.self) {
            try await manager.apply(
                .update(server),
                credentials: ServerCredentials(serverId: server.id)
            )
        }
        await #expect(throws: ServerDataMutationTransactionError.self) {
            try await manager.updateLastConnected(for: server)
        }
        await #expect(throws: ServerDataMutationTransactionError.self) {
            try await manager.clearLocalDataAndResync()
        }

        #expect(manager.servers.first?.lastConnected == nil)
        #expect(local.servers.first?.lastConnected == nil)
        #expect(sync.clearCount == 0)
    }

    @Test
    func workspaceUpsertQueueFailureKeepsDurableLocalStateAndSyncIntent() async throws {
        let workspace = makeWorkspace()
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        let credentials = ServerManagerCredentialRepositoryFake()
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(local: local, credentials: credentials, sync: sync)
        var editedWorkspace = workspace
        editedWorkspace.name = "Changed"

        await #expect(throws: VVTermError.self) {
            try await manager.updateWorkspace(editedWorkspace)
        }

        #expect(manager.workspaces.map(\.name) == ["Changed"])
        #expect(local.workspaces.map(\.name) == ["Changed"])
        #expect(local.serverMutationJournal?.phase == .enqueueing)
        #expect(sync.enqueuedServerMutations.isEmpty)

        sync.enqueueError = nil
        let recovered = try #require(
            try manager.stateStore.makeServerDataMutationTransaction(
                mutationQueue: sync,
                credentials: credentials
            ).resumePending()
        )

        #expect(recovered.phase == .complete)
        #expect(sync.enqueuedServerMutations.count == 1)
        guard case .workspaceUpsert(let queuedWorkspace) = sync.enqueuedServerMutations[0].payload else {
            Issue.record("Expected a workspace upsert")
            return
        }
        #expect(queuedWorkspace.name == "Changed")
    }

    @Test
    func workspaceReorderQueueFailureNeverCommitsOnlyPartOfTheBatch() async throws {
        let first = makeWorkspace()
        let second = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Second",
            order: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [first, second])
        let credentials = ServerManagerCredentialRepositoryFake()
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(local: local, credentials: credentials, sync: sync)

        await #expect(throws: VVTermError.self) {
            try await manager.reorderWorkspaces(from: IndexSet(integer: 0), to: 2)
        }

        #expect(manager.workspaces.map(\.id) == [second.id, first.id])
        #expect(local.workspaces.map(\.id) == [second.id, first.id])
        #expect(local.serverMutationJournal?.plan.pendingMutations.count == 2)
        #expect(sync.enqueuedServerMutations.isEmpty)

        sync.enqueueError = nil
        let recovered = try #require(
            try manager.stateStore.makeServerDataMutationTransaction(
                mutationQueue: sync,
                credentials: credentials
            ).resumePending()
        )

        #expect(recovered.phase == .complete)
        #expect(sync.enqueuedServerMutations.count == 2)
    }

    @Test
    func pendingWorkspaceMutationBlocksOtherMutationsAndAuthoritativeResync() async throws {
        let first = makeWorkspace()
        let second = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Second",
            order: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let custom = ServerEnvironment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Review",
            shortName: "Rev",
            colorHex: "#123456"
        )
        var workspaceWithEnvironment = second
        workspaceWithEnvironment.environments.append(custom)
        let local = ServerLocalRepositoryFake(
            servers: [],
            workspaces: [first, workspaceWithEnvironment]
        )
        let credentials = ServerManagerCredentialRepositoryFake()
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(local: local, credentials: credentials, sync: sync)
        var editedFirst = first
        editedFirst.name = "Pending"

        await #expect(throws: VVTermError.self) {
            try await manager.updateWorkspace(editedFirst)
        }
        await #expect(throws: ServerDataMutationTransactionError.self) {
            try await manager.deleteWorkspace(workspaceWithEnvironment)
        }
        await #expect(throws: ServerDataMutationTransactionError.self) {
            _ = try await manager.deleteEnvironment(custom, in: workspaceWithEnvironment)
        }
        await #expect(throws: ServerDataMutationTransactionError.self) {
            try await manager.clearLocalDataAndResync()
        }

        #expect(local.serverMutationJournal?.plan.kind == .workspaceUpsert(first.id))
        #expect(local.workspaces.map(\.id) == [first.id, second.id])
        #expect(sync.clearCount == 0)
    }

    private func makeManager(
        local: ServerLocalRepositoryFake,
        credentials: ServerManagerCredentialRepositoryFake,
        sync: ServerSyncRepositoryFake
    ) -> ServerManager {
        let now = { Date(timeIntervalSinceReferenceDate: 10_000) }
        var ids = (1...20).map {
            UUID(uuidString: String(format: "90000000-0000-0000-0000-%012d", $0))!
        }
        let makeID = { ids.removeFirst() }
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: local,
                preferences: ServerManagerPreferencesFake(),
                freePlanTracker: FreePlanAssignmentTrackerFake(),
                isSyncEnabled: { false },
                now: now,
                makeID: makeID,
                defaultWorkspaceName: { "My Servers" },
                canonicalDefaultWorkspaceNames: { ["My Servers"] }
            )
        )
        return ServerManager(
            dependencies: ServerManagerDependencies(
                stateStore: stateStore,
                remoteRepository: ServerRemoteRepositoryFake(),
                syncRepository: sync,
                credentialRepository: credentials,
                actionAuthorizer: ProtectedServerActionAuthorizerFake(),
                knownHosts: ServerKnownHostRepositoryFake(),
                isRemoteSchemaError: { _ in false },
                now: now,
                makeID: makeID
            ),
            startsAutomatically: false
        )
    }

    private func makeWorkspace() -> Workspace {
        Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Workspace",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID, host: String = "server.example.test") -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspaceID,
            name: "Server",
            host: host,
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
