import Foundation
import Testing
@testable import VVTerm


@Suite(.serialized)
@MainActor
struct ServerManagerLoadLifecycleTests {
    @Test
    func syncDisableCancelsLoadAndRejectsCancellationIgnoringCompletion() async {
        var syncEnabled = true
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, _ in await gate.wait() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled }
        )
        let loadTask = Task { await manager.loadData() }

        #expect(await gate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(await gate.waitUntilCancelled())
        let checkpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
        )
        gate.resolve(
            makeRemoteChanges(
                workspaceName: "Late Remote",
                checkpoint: checkpoint
            )
        )
        await loadTask.value

        #expect(manager.workspaces.isEmpty)
        #expect(manager.servers.isEmpty)
        #expect(manager.stateStore.loadState.phase == .idle)
        #expect(sync.drainCount == 0)
        #expect(remote.acceptedCheckpoints.isEmpty)
    }

    @Test
    func restartAcceptsCheckpointOnlyAfterRemoteBatchPersists() async {
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [])
        local.persistError = TestTransactionError.persistence
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        let checkpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
        )
        let changes = makeRemoteChanges(
            workspaceName: "Durable Remote",
            checkpoint: checkpoint
        )
        remote.fetchHandler = { _, _ in changes }
        let sync = ServerSyncRepositoryFake()
        let firstManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await firstManager.loadData()

        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(local.workspaces.isEmpty)
        #expect(firstManager.workspaces.isEmpty)
        #expect(sync.drainCount == 0)

        local.persistError = nil
        let restartedManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )
        await restartedManager.loadData()

        #expect(remote.fetchCount == 2)
        #expect(remote.acceptedCheckpoints == [checkpoint])
        #expect(local.workspaces.map(\.name) == ["Durable Remote"])
        #expect(sync.drainCount == 1)
    }

    @Test
    func clearAndResyncForcesFullReplacementWithoutClearingFirst() async throws {
        let oldWorkspace = makeWorkspace(name: "Old Local")
        let oldServer = makeServer(workspaceID: oldWorkspace.id)
        let remoteWorkspace = makeWorkspace(name: "Remote")
        let remoteServer = makeServer(workspaceID: remoteWorkspace.id)
        let local = ServerLocalRepositoryFake(
            servers: [oldServer],
            workspaces: [oldWorkspace]
        )
        let checkpoint = ServerRemoteChangeCheckpoint(id: UUID())
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { forceFullFetch, _ in
            #expect(forceFullFetch)
            return ServerRemoteChanges(
                servers: [remoteServer],
                workspaces: [remoteWorkspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: checkpoint
            )
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        try await manager.clearLocalDataAndResync()

        #expect(manager.workspaces == [remoteWorkspace])
        #expect(manager.servers == [remoteServer])
        #expect(local.workspaces == [remoteWorkspace])
        #expect(local.servers == [remoteServer])
        #expect(remote.acceptedCheckpoints == [checkpoint])
        #expect(sync.clearCount == 1)
    }

    @Test
    func clearAndResyncCanExplicitlyAcceptAnEmptyCloudSnapshot() async throws {
        let workspace = makeWorkspace(name: "Local")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let checkpoint = ServerRemoteChangeCheckpoint(id: UUID())
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { forceFullFetch, _ in
            #expect(forceFullFetch)
            return ServerRemoteChanges(
                servers: [],
                workspaces: [],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: checkpoint
            )
        }
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )

        try await manager.clearLocalDataAndResync()

        #expect(manager.servers.isEmpty)
        #expect(manager.workspaces.isEmpty)
        #expect(remote.acceptedCheckpoints == [checkpoint])
        #expect(manager.stateStore.ambiguousCloudRecovery == nil)
    }

    @Test
    func clearAndResyncFailureKeepsExistingLocalSnapshot() async {
        let workspace = makeWorkspace(name: "Existing")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in throw ServerRemoteTestError.schema }
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )

        await #expect(throws: ServerRemoteTestError.self) {
            try await manager.clearLocalDataAndResync()
        }

        #expect(manager.workspaces == [workspace])
        #expect(manager.servers == [server])
        #expect(local.workspaces == [workspace])
        #expect(local.servers == [server])
        #expect(remote.acceptedCheckpoints.isEmpty)
    }

    @Test
    func clearAndResyncPersistenceFailureKeepsExistingLocalSnapshot() async {
        let oldWorkspace = makeWorkspace(name: "Existing")
        let oldServer = makeServer(workspaceID: oldWorkspace.id)
        let remoteWorkspace = makeWorkspace(name: "Remote")
        let local = ServerLocalRepositoryFake(
            servers: [oldServer],
            workspaces: [oldWorkspace]
        )
        local.persistError = TestTransactionError.persistence
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [remoteWorkspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(id: UUID())
            )
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await #expect(throws: TestTransactionError.self) {
            try await manager.clearLocalDataAndResync()
        }

        #expect(manager.workspaces == [oldWorkspace])
        #expect(manager.servers == [oldServer])
        #expect(local.workspaces == [oldWorkspace])
        #expect(local.servers == [oldServer])
        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(sync.clearCount == 0)
    }

    @Test
    func clearAndResyncQueueFailureRollsBackSnapshotAndCheckpoint() async {
        let oldWorkspace = makeWorkspace(name: "Existing")
        let oldServer = makeServer(workspaceID: oldWorkspace.id)
        let remoteWorkspace = makeWorkspace(name: "Remote")
        let local = ServerLocalRepositoryFake(
            servers: [oldServer],
            workspaces: [oldWorkspace]
        )
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [remoteWorkspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(id: UUID())
            )
        }
        let sync = ServerSyncRepositoryFake()
        sync.clearError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await #expect(throws: ServerSyncRepositoryTestError.self) {
            try await manager.clearLocalDataAndResync()
        }

        #expect(manager.workspaces == [oldWorkspace])
        #expect(manager.servers == [oldServer])
        #expect(local.workspaces == [oldWorkspace])
        #expect(local.servers == [oldServer])
        #expect(remote.acceptedCheckpoints.isEmpty)
    }

    @Test
    func automaticEmptyFullFetchPreservesLocalDataAndCheckpoint() async {
        let workspace = makeWorkspace(name: "Local after account change")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let checkpoint = ServerRemoteChangeCheckpoint(id: UUID())
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: checkpoint
            )
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await manager.loadData()

        #expect(manager.servers == [server])
        #expect(manager.workspaces == [workspace])
        #expect(local.servers == [server])
        #expect(local.workspaces == [workspace])
        #expect(local.ambiguousCloudRecoveryBackup?.servers == [server])
        #expect(local.ambiguousCloudRecoveryBackup?.workspaces == [workspace])
        #expect(manager.stateStore.ambiguousCloudRecovery != nil)
        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(sync.drainCount == 0)

        let restartedManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )
        #expect(restartedManager.stateStore.ambiguousCloudRecovery != nil)
    }

    @Test
    func durableRecoveryDecisionBlocksAutomaticFetchAfterRestart() async throws {
        let workspace = makeWorkspace(name: "Local")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(id: UUID())
            )
        }
        let sync = ServerSyncRepositoryFake()
        let firstManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await firstManager.loadData()
        #expect(remote.fetchCount == 1)

        let unrelatedWorkspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
            name: "Other Account",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [unrelatedWorkspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(id: UUID())
            )
        }
        let restartedManager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )

        await restartedManager.loadData()

        #expect(remote.fetchCount == 1)
        #expect(restartedManager.servers == [server])
        #expect(restartedManager.workspaces == [workspace])
        #expect(local.ambiguousCloudRecoveryBackup != nil)
        #expect(remote.acceptedCheckpoints.isEmpty)

        try await restartedManager.resolveAmbiguousCloudRecovery(.replaceWithCloud)

        #expect(remote.fetchCount == 2)
        #expect(remote.fetchForceFullModes == [false, true])
        #expect(restartedManager.servers.isEmpty)
        #expect(restartedManager.workspaces == [unrelatedWorkspace])
        #expect(local.ambiguousCloudRecoveryBackup == nil)
    }

    @Test
    func nonEmptyFullFetchWithUnexplainedMissingLocalIDsRequiresDecision() async {
        let localWorkspace = makeWorkspace(name: "Local")
        let localServer = makeServer(workspaceID: localWorkspace.id)
        let cloudWorkspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
            name: "Cloud",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let cloudServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000099")!,
            workspaceId: cloudWorkspace.id,
            name: "Cloud Server",
            host: "cloud.example.test",
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let local = ServerLocalRepositoryFake(
            servers: [localServer],
            workspaces: [localWorkspace]
        )
        let checkpoint = ServerRemoteChangeCheckpoint(id: UUID())
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [cloudServer],
                workspaces: [cloudWorkspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: checkpoint
            )
        }
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )

        await manager.loadData()

        #expect(manager.servers == [localServer])
        #expect(manager.workspaces == [localWorkspace])
        #expect(local.ambiguousCloudRecoveryBackup?.servers == [localServer])
        #expect(local.ambiguousCloudRecoveryBackup?.workspaces == [localWorkspace])
        #expect(manager.stateStore.ambiguousCloudRecovery != nil)
        #expect(remote.acceptedCheckpoints.isEmpty)
    }

    @Test
    func emptyFullFetchWithCompleteDeletionEvidenceCanReplaceLocalData() async {
        let workspace = makeWorkspace(name: "Deleted remotely")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let checkpoint = ServerRemoteChangeCheckpoint(id: UUID())
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [],
                deletedServerIDs: [server.id],
                deletedWorkspaceIDs: [workspace.id],
                isFullFetch: true,
                checkpoint: checkpoint
            )
        }
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )

        await manager.loadData()

        #expect(manager.servers.isEmpty)
        #expect(manager.workspaces.isEmpty)
        #expect(local.ambiguousCloudRecoveryBackup == nil)
        #expect(manager.stateStore.ambiguousCloudRecovery == nil)
        #expect(remote.acceptedCheckpoints == [checkpoint])
    }

    @Test
    func ambiguousEmptyFetchCanKeepLocalData() async throws {
        let fixture = makeAmbiguousEmptyFetchFixture()

        await fixture.manager.loadData()
        try await fixture.manager.resolveAmbiguousCloudRecovery(.keepLocal)

        #expect(fixture.manager.servers == [fixture.server])
        #expect(fixture.manager.workspaces == [fixture.workspace])
        #expect(fixture.remote.savedServers.isEmpty)
        #expect(fixture.remote.savedWorkspaces.isEmpty)
        #expect(fixture.remote.acceptedCheckpoints == [fixture.checkpoint])
        #expect(fixture.remote.fetchForceFullModes == [false, true])
        #expect(fixture.local.ambiguousCloudRecoveryBackup == nil)
        #expect(fixture.manager.stateStore.ambiguousCloudRecovery == nil)
    }

    @Test
    func ambiguousEmptyFetchCanUploadLocalData() async throws {
        let fixture = makeAmbiguousEmptyFetchFixture()

        await fixture.manager.loadData()
        try await fixture.manager.resolveAmbiguousCloudRecovery(.uploadLocal)

        #expect(fixture.remote.savedWorkspaces == [fixture.workspace])
        #expect(fixture.remote.savedServers == [fixture.server])
        #expect(fixture.remote.acceptedCheckpoints == [fixture.checkpoint])
        #expect(fixture.local.ambiguousCloudRecoveryBackup == nil)
        #expect(fixture.manager.stateStore.ambiguousCloudRecovery == nil)
    }

    @Test
    func failedAmbiguousUploadKeepsLocalBackupAndCheckpointPending() async {
        let fixture = makeAmbiguousEmptyFetchFixture()
        fixture.remote.saveWorkspaceHandler = { _ in
            throw ServerRemoteTestError.schema
        }

        await fixture.manager.loadData()
        await #expect(throws: ServerRemoteTestError.self) {
            try await fixture.manager.resolveAmbiguousCloudRecovery(.uploadLocal)
        }

        #expect(fixture.manager.servers == [fixture.server])
        #expect(fixture.manager.workspaces == [fixture.workspace])
        #expect(fixture.local.ambiguousCloudRecoveryBackup != nil)
        #expect(fixture.manager.stateStore.ambiguousCloudRecovery != nil)
        #expect(fixture.remote.acceptedCheckpoints.isEmpty)
    }

    @Test
    func ambiguousEmptyFetchCanReplaceLocalDataAfterExplicitChoice() async throws {
        let fixture = makeAmbiguousEmptyFetchFixture()

        await fixture.manager.loadData()
        try await fixture.manager.resolveAmbiguousCloudRecovery(.replaceWithCloud)

        #expect(fixture.manager.servers.isEmpty)
        #expect(fixture.manager.workspaces.isEmpty)
        #expect(fixture.local.servers.isEmpty)
        #expect(fixture.local.workspaces.isEmpty)
        #expect(fixture.sync.clearCount == 1)
        #expect(fixture.remote.acceptedCheckpoints == [fixture.checkpoint])
        #expect(fixture.remote.fetchForceFullModes == [false, true])
        #expect(fixture.local.ambiguousCloudRecoveryBackup == nil)
        #expect(fixture.manager.stateStore.ambiguousCloudRecovery == nil)
    }

    @Test
    func fullFetchRemoteDeletionDoesNotBackfillStaleLocalServer() async {
        let workspace = makeWorkspace(name: "Workspace")
        let staleServer = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(
            servers: [staleServer],
            workspaces: [workspace]
        )
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [workspace],
                deletedServerIDs: [staleServer.id],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(id: UUID())
            )
        }
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )

        await manager.loadData()

        #expect(manager.servers.isEmpty)
        #expect(remote.savedServers.isEmpty)
    }

    @Test
    func failedFullFetchRestoresBootstrapFetchIdentityUntilCheckpointAcceptance() async {
        let workspace = makeWorkspace(name: "Bootstrap")
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        local.persistError = TestTransactionError.persistence
        let preferences = ServerManagerPreferencesFake()
        preferences.pendingBootstrapWorkspaceID = workspace.id
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        let checkpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000006")!
        )
        let changes = ServerRemoteChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: true,
            checkpoint: checkpoint
        )
        remote.fetchHandler = { _, _ in changes }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            preferences: preferences,
            isSyncEnabled: { true }
        )

        await manager.loadData()

        #expect(remote.fetchForceFullModes == [true])
        #expect(manager.stateStore.transientBootstrapWorkspaceID == workspace.id)
        #expect(manager.workspaces == [workspace])
        #expect(manager.stateStore.ambiguousCloudRecovery == nil)
        #expect(remote.acceptedCheckpoints.isEmpty)
        #expect(sync.drainCount == 0)

        local.persistError = nil
        await manager.loadData()

        #expect(remote.fetchForceFullModes == [true, true])
        #expect(manager.stateStore.transientBootstrapWorkspaceID == nil)
        #expect(remote.acceptedCheckpoints == [checkpoint])
        #expect(sync.drainCount == 1)
    }

    @Test
    func staleLoadGenerationCannotReplaceNewerLoad() async {
        var syncEnabled = true
        let firstGate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, fetchCount in
            if fetchCount == 1 {
                return await firstGate.wait()
            }
            return makeRemoteChanges(workspaceName: "Current Remote")
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled }
        )
        let staleLoadTask = Task { await manager.loadData() }

        #expect(await firstGate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()
        #expect(await firstGate.waitUntilCancelled())

        syncEnabled = true
        await manager.loadData()
        #expect(manager.workspaces.map(\.name) == ["Current Remote"])

        firstGate.resolve(makeRemoteChanges(workspaceName: "Stale Remote"))
        await staleLoadTask.value

        #expect(manager.workspaces.map(\.name) == ["Current Remote"])
        #expect(sync.drainCount == 1)
    }

    @Test
    func blockedAutomaticLoadDoesNotRetainOwnerAndObservesCancellation() async {
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, _ in await gate.wait() }
        var manager: ServerManager? = makeManager(
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true },
            startsAutomatically: true
        )
        weak var releasedManager: ServerManager?
        releasedManager = manager

        #expect(await gate.waitUntilStarted())
        manager = nil

        #expect(await gate.waitUntilCancelled())
        for _ in 0..<2_000 where releasedManager != nil {
            await Task.yield()
        }
        #expect(releasedManager == nil)

        gate.resolve(makeRemoteChanges(workspaceName: "Ignored Remote"))
    }

    @Test
    func blockedAutomaticLoadDoesNotRetainCoordinator() async {
        let gate = ServerCancellationIgnoringGate<ServerRemoteChanges>()
        let remote = ServerRemoteRepositoryFake()
        remote.fetchHandler = { _, _ in await gate.wait() }
        var coordinator: ServerRemoteSyncCoordinator? = makeRemoteSyncCoordinator(
            remote: remote,
            sync: ServerSyncRepositoryFake(),
            isSyncEnabled: { true }
        )
        weak var releasedCoordinator: ServerRemoteSyncCoordinator?
        releasedCoordinator = coordinator
        coordinator?.startAutomaticLoad()

        #expect(await gate.waitUntilStarted())
        coordinator = nil

        #expect(await gate.waitUntilCancelled())
        for _ in 0..<2_000 where releasedCoordinator != nil {
            await Task.yield()
        }
        #expect(releasedCoordinator == nil)

        gate.resolve(makeRemoteChanges(workspaceName: "Ignored Remote"))
    }

    @Test
    func syncDisableCancelsBlockedStartupRecoveryBeforeRemoteLoad() async throws {
        var syncEnabled = true
        let drainGate = ServerCancellationIgnoringGate<Void>()
        let sync = ServerSyncRepositoryFake()
        sync.drainHandler = { await drainGate.wait() }
        let remote = ServerRemoteRepositoryFake()
        let manager = makeManager(
            local: try makePendingDeletionLocal(),
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled },
            startsAutomatically: true
        )

        #expect(await drainGate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(await drainGate.waitUntilCancelled())
        drainGate.resolve(())
        for _ in 0..<2_000 where sync.completedDrainCount == 0 {
            await Task.yield()
        }
        await Task.yield()

        #expect(sync.completedDrainCount == 1)
        #expect(remote.fetchCount == 0)
    }

    @Test
    func blockedStartupRecoveryDoesNotRetainOwner() async throws {
        let drainGate = ServerCancellationIgnoringGate<Void>()
        let sync = ServerSyncRepositoryFake()
        sync.drainHandler = { await drainGate.wait() }
        let remote = ServerRemoteRepositoryFake()
        var manager: ServerManager? = makeManager(
            local: try makePendingDeletionLocal(),
            remote: remote,
            sync: sync,
            isSyncEnabled: { true },
            startsAutomatically: true
        )
        weak var releasedManager: ServerManager?
        releasedManager = manager

        #expect(await drainGate.waitUntilStarted())
        manager = nil

        #expect(await drainGate.waitUntilCancelled())
        for _ in 0..<2_000 where releasedManager != nil {
            await Task.yield()
        }
        #expect(releasedManager == nil)
        #expect(remote.fetchCount == 0)

        drainGate.resolve(())
    }

    @Test
    func syncDisableDuringSchemaInitializationRejectsLateSaveCompletion() async {
        var syncEnabled = true
        let workspace = makeWorkspace(name: "Local")
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        let saveGate = ServerCancellationIgnoringGate<Void>()
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in throw ServerRemoteTestError.schema }
        remote.saveWorkspaceHandler = { _ in await saveGate.wait() }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { syncEnabled },
            isRemoteSchemaError: { _ in true }
        )
        let loadTask = Task { await manager.loadData() }

        #expect(await saveGate.waitUntilStarted())
        syncEnabled = false
        manager.handleSyncDisabled()

        #expect(await saveGate.waitUntilCancelled())
        saveGate.resolve(())
        await loadTask.value

        #expect(manager.workspaces == [workspace])
        #expect(manager.stateStore.loadState.phase == .idle)
        #expect(remote.savedWorkspaces == [workspace])
        #expect(remote.savedServers.isEmpty)
        #expect(sync.drainCount == 0)
    }

    @Test
    func schemaInitializationFailureLeavesCoordinatorReadyForRetry() async {
        let workspace = makeWorkspace(name: "Local")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, fetchCount in
            if fetchCount == 1 {
                throw ServerRemoteTestError.schema
            }
            return ServerRemoteChanges(
                servers: [server],
                workspaces: [workspace],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: ServerRemoteChangeCheckpoint(
                    id: UUID(uuidString: "80000000-0000-0000-0000-000000000003")!
                )
            )
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true },
            isRemoteSchemaError: { _ in true }
        )

        await manager.loadData()

        #expect(remote.savedWorkspaces == [workspace])
        #expect(remote.savedServers == [server])
        guard case .failed = manager.stateStore.loadState.phase else {
            Issue.record("Expected the first schema load to fail after initialization")
            return
        }

        await manager.loadData()

        #expect(remote.fetchCount == 2)
        #expect(manager.workspaces == [workspace])
        #expect(manager.servers == [server])
        #expect(manager.stateStore.loadState.phase == .idle)
        #expect(sync.drainCount == 1)
    }

    @Test
    func independentManagersKeepRemoteCoordinatorsAndSnapshotsIsolated() async {
        let firstRemote = ServerRemoteRepositoryFake()
        firstRemote.fetchHandler = { _, _ in
            self.makeRemoteChanges(workspaceName: "First Remote")
        }
        let secondRemote = ServerRemoteRepositoryFake()
        secondRemote.fetchHandler = { _, _ in
            self.makeRemoteChanges(workspaceName: "Second Remote")
        }
        let firstSync = ServerSyncRepositoryFake()
        let secondSync = ServerSyncRepositoryFake()
        let firstDependencies = makeDependencies(
            local: nil,
            remote: firstRemote,
            sync: firstSync,
            isSyncEnabled: { true },
            isRemoteSchemaError: { _ in false }
        )
        let secondDependencies = makeDependencies(
            local: nil,
            remote: secondRemote,
            sync: secondSync,
            isSyncEnabled: { true },
            isRemoteSchemaError: { _ in false }
        )
        let firstManager = ServerManager(
            dependencies: firstDependencies,
            startsAutomatically: false
        )
        let secondManager = ServerManager(
            dependencies: secondDependencies,
            startsAutomatically: false
        )

        await firstManager.loadData()
        await secondManager.loadData()

        #expect(firstManager.workspaces.map(\.name) == ["First Remote"])
        #expect(secondManager.workspaces.map(\.name) == ["Second Remote"])
        #expect(firstManager.stateStore !== secondManager.stateStore)
        #expect(firstDependencies.remoteSyncCoordinator !== secondDependencies.remoteSyncCoordinator)
        #expect(firstSync.drainCount == 1)
        #expect(secondSync.drainCount == 1)
    }

    private func makeManager(
        local: ServerLocalRepositoryFake? = nil,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        preferences: ServerManagerPreferencesFake? = nil,
        isSyncEnabled: @escaping () -> Bool,
        isRemoteSchemaError: @escaping (Error) -> Bool = { _ in false },
        startsAutomatically: Bool = false
    ) -> ServerManager {
        ServerManager(
            dependencies: makeDependencies(
                local: local,
                remote: remote,
                sync: sync,
                preferences: preferences,
                isSyncEnabled: isSyncEnabled,
                isRemoteSchemaError: isRemoteSchemaError
            ),
            startsAutomatically: startsAutomatically
        )
    }

    private func makeAmbiguousEmptyFetchFixture() -> (
        manager: ServerManager,
        local: ServerLocalRepositoryFake,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        workspace: Workspace,
        server: Server,
        checkpoint: ServerRemoteChangeCheckpoint
    ) {
        let workspace = makeWorkspace(name: "Local")
        let server = makeServer(workspaceID: workspace.id)
        let local = ServerLocalRepositoryFake(servers: [server], workspaces: [workspace])
        let checkpoint = ServerRemoteChangeCheckpoint(id: UUID())
        let remote = ServerRemoteRepositoryFake(isAvailable: true)
        remote.fetchHandler = { _, _ in
            ServerRemoteChanges(
                servers: [],
                workspaces: [],
                deletedServerIDs: [],
                deletedWorkspaceIDs: [],
                isFullFetch: true,
                checkpoint: checkpoint
            )
        }
        let sync = ServerSyncRepositoryFake()
        let manager = makeManager(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: { true }
        )
        return (manager, local, remote, sync, workspace, server, checkpoint)
    }

    private func makeRemoteSyncCoordinator(
        local: ServerLocalRepositoryFake? = nil,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        isSyncEnabled: @escaping () -> Bool,
        isRemoteSchemaError: @escaping (Error) -> Bool = { _ in false }
    ) -> ServerRemoteSyncCoordinator {
        makeDependencies(
            local: local,
            remote: remote,
            sync: sync,
            isSyncEnabled: isSyncEnabled,
            isRemoteSchemaError: isRemoteSchemaError
        ).remoteSyncCoordinator
    }

    private func makeDependencies(
        local: ServerLocalRepositoryFake?,
        remote: ServerRemoteRepositoryFake,
        sync: ServerSyncRepositoryFake,
        preferences: ServerManagerPreferencesFake? = nil,
        isSyncEnabled: @escaping () -> Bool,
        isRemoteSchemaError: @escaping (Error) -> Bool
    ) -> ServerManagerDependencies {
        let now = { Date(timeIntervalSinceReferenceDate: 20_000) }
        let makeID = { UUID(uuidString: "90000000-0000-0000-0000-000000000002")! }
        let stateStore = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: local ?? ServerLocalRepositoryFake(servers: [], workspaces: []),
                preferences: preferences ?? ServerManagerPreferencesFake(),
                freePlanTracker: FreePlanAssignmentTrackerFake(),
                isSyncEnabled: isSyncEnabled,
                now: now,
                makeID: makeID,
                defaultWorkspaceName: { "My Servers" },
                canonicalDefaultWorkspaceNames: { ["My Servers"] }
            )
        )
        return ServerManagerDependencies(
            stateStore: stateStore,
            remoteRepository: remote,
            syncRepository: sync,
            credentialRepository: ServerManagerCredentialRepositoryFake(),
            actionAuthorizer: ProtectedServerActionAuthorizerFake(),
            knownHosts: ServerKnownHostRepositoryFake(),
            isRemoteSchemaError: isRemoteSchemaError,
            now: now,
            makeID: makeID
        )
    }

    @Test
    func queuePersistenceFailureIsReturnedWithoutStartingDrain() async {
        let workspace = makeWorkspace(name: "Local")
        let sync = ServerSyncRepositoryFake()
        sync.enqueueError = ServerSyncRepositoryTestError.rejected
        let manager = makeManager(
            local: ServerLocalRepositoryFake(servers: [], workspaces: [workspace]),
            remote: ServerRemoteRepositoryFake(),
            sync: sync,
            isSyncEnabled: { true }
        )
        let server = makeServer(workspaceID: workspace.id)

        await #expect(throws: VVTermError.self) {
            try await manager.apply(
                .create(server),
                credentials: ServerCredentials(serverId: server.id)
            )
        }

        #expect(sync.drainCount == 0)
    }

    private func makeWorkspace(name: String) -> Workspace {
        Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            name: name,
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID) -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            workspaceId: workspaceID,
            name: "Server",
            host: "server.example.test",
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeRemoteChanges(
        workspaceName: String,
        checkpoint: ServerRemoteChangeCheckpoint = ServerRemoteChangeCheckpoint(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
        )
    ) -> ServerRemoteChanges {
        ServerRemoteChanges(
            servers: [],
            workspaces: [
                Workspace(
                    name: workspaceName,
                    order: 0,
                    createdAt: .distantPast,
                    updatedAt: .distantPast
                )
            ],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [],
            isFullFetch: true,
            checkpoint: checkpoint
        )
    }

    private func makePendingDeletionLocal() throws -> ServerLocalRepositoryFake {
        let workspace = Workspace(
            name: "Pending Deletion",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let plan = try #require(WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: [],
            workspaces: [workspace],
            id: UUID(),
            mutationIDs: [UUID()],
            mutationDate: .distantPast
        ))
        let local = ServerLocalRepositoryFake(servers: [], workspaces: [workspace])
        local.serverMutationJournal = ServerDataMutationJournal(
            plan: ServerDataMutationPlan(workspaceDeletion: plan)
        )
        return local
    }
}
