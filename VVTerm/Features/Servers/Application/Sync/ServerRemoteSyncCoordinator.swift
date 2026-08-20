import Foundation
import os.log

@MainActor
struct ServerRemoteSyncCoordinatorDependencies {
    let stateStore: ServerStateStore
    let remoteRepository: any ServerRemoteRepository
    let syncRepository: any ServerSyncRepository
    let credentialRepository: any ServerManagerCredentialRepository
    let knownHosts: any ServerKnownHostRepository
    let isRemoteSchemaError: (Error) -> Bool
    let now: () -> Date
    let makeID: () -> UUID
}

@MainActor
final class ServerRemoteSyncCoordinator {
    private nonisolated final class LoadGeneration: Sendable {}

    private nonisolated struct ActiveLoad: Sendable {
        let operationID: UUID
        let generation: LoadGeneration
        let task: Task<Void, Never>
    }

    private struct FullFetchBackfillResult {
        let changes: ServerRemoteChanges
        let canReplaceLocalState: Bool
    }

    private let dependencies: ServerRemoteSyncCoordinatorDependencies
    private let stateStore: ServerStateStore
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "ServerRemoteSyncCoordinator"
    )
    private var activeLoad: ActiveLoad?
    private var startupTask: Task<Void, Never>?

    init(dependencies: ServerRemoteSyncCoordinatorDependencies) {
        self.dependencies = dependencies
        stateStore = dependencies.stateStore
    }

    deinit {
        startupTask?.cancel()
        activeLoad?.task.cancel()
    }

    func startAutomaticLoad() {
        guard startupTask == nil else { return }

        let stateStore = dependencies.stateStore
        let syncRepository = dependencies.syncRepository
        startupTask = Task { [weak self, stateStore, syncRepository] in
            let mutationRecovery = self?.recoverPendingServerDataMutation()
            if case .pending? = mutationRecovery {
                return
            }
            if mutationRecovery == .complete, stateStore.isSyncEnabled {
                await syncRepository.drainPendingMutations()
            }
            guard !Task.isCancelled else { return }
            self?.beginLoadingIfNeeded()
        }
    }

    func loadData() async {
        guard let task = beginLoadingIfNeeded() else { return }
        await task.value
    }

    func handleSyncDisabled() {
        startupTask?.cancel()
        startupTask = nil
        invalidateActiveLoad()
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "local_only"
        )
    }

    func clearLocalDataAndResync() async throws {
        logger.info("Replacing local server data from an authoritative CloudKit fetch...")

        try stateStore.requireNoPendingServerDataMutation()

        if let activeLoad {
            await activeLoad.task.value
        }

        guard stateStore.isSyncEnabled, dependencies.remoteRepository.isAvailable else {
            throw AuthoritativeServerResyncError.remoteUnavailable
        }

        let previousServers = stateStore.servers
        let previousWorkspaces = stateStore.workspaces
        let previousBootstrapWorkspaceID = stateStore.transientBootstrapWorkspaceID
        let changes = try await dependencies.remoteRepository.fetchServerChanges(
            forceFullFetch: true
        )
        guard changes.isFullFetch else {
            throw AuthoritativeServerResyncError.incompleteSnapshot
        }

        stateStore.applyRemoteChanges(changes)
        do {
            try stateStore.persistCurrentCollectionsForRemoteAcceptance()
            try dependencies.syncRepository.clearPendingServerAndWorkspaceMutations()
        } catch {
            stateStore.replaceCollections(
                servers: previousServers,
                workspaces: previousWorkspaces
            )
            stateStore.restorePendingBootstrapWorkspaceID(previousBootstrapWorkspaceID)
            try? stateStore.persistCurrentCollectionsForRemoteAcceptance()
            throw error
        }

        stateStore.restorePendingBootstrapWorkspaceID(nil)
        try dependencies.remoteRepository.acceptServerChanges(changes.checkpoint)
        try clearAmbiguousCloudRecoveryIfNeeded()
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "authoritative_resync"
        )

        logger.info(
            "Authoritative re-sync complete: \(self.stateStore.workspaces.count) workspaces, \(self.stateStore.servers.count) servers"
        )
    }

    func resolveAmbiguousCloudRecovery(
        _ choice: AmbiguousCloudRecoveryChoice
    ) async throws {
        if let activeLoad {
            await activeLoad.task.value
        }
        guard stateStore.ambiguousCloudRecovery != nil else { return }
        try stateStore.requireNoPendingServerDataMutation()
        guard stateStore.isSyncEnabled,
              dependencies.remoteRepository.isAvailable else {
            throw AmbiguousCloudRecoveryError.remoteUnavailable
        }
        let changes = try await dependencies.remoteRepository.fetchServerChanges(
            forceFullFetch: true
        )
        guard changes.isFullFetch else {
            throw AmbiguousCloudRecoveryError.incompleteSnapshot
        }

        switch choice {
        case .keepLocal:
            try stateStore.persistCurrentCollectionsForRemoteAcceptance()
            try dependencies.remoteRepository.acceptServerChanges(changes.checkpoint)

        case .uploadLocal:
            try stateStore.persistCurrentCollectionsForRemoteAcceptance()
            for workspace in stateStore.workspaces {
                try await dependencies.remoteRepository.saveWorkspace(workspace)
            }
            for server in stateStore.servers {
                try await dependencies.remoteRepository.saveServer(server)
            }
            try dependencies.remoteRepository.acceptServerChanges(changes.checkpoint)

        case .replaceWithCloud:
            let previousServers = stateStore.servers
            let previousWorkspaces = stateStore.workspaces
            let previousBootstrapWorkspaceID = stateStore.transientBootstrapWorkspaceID
            stateStore.applyRemoteChanges(changes)
            do {
                try stateStore.persistCurrentCollectionsForRemoteAcceptance()
                try dependencies.syncRepository.clearPendingServerAndWorkspaceMutations()
            } catch {
                stateStore.replaceCollections(
                    servers: previousServers,
                    workspaces: previousWorkspaces
                )
                stateStore.restorePendingBootstrapWorkspaceID(previousBootstrapWorkspaceID)
                try? stateStore.persistCurrentCollectionsForRemoteAcceptance()
                throw error
            }
            stateStore.restorePendingBootstrapWorkspaceID(nil)
            try dependencies.remoteRepository.acceptServerChanges(changes.checkpoint)
        }

        try clearAmbiguousCloudRecoveryIfNeeded()
        stateStore.resetLoading()
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "ambiguous_cloud_recovery"
        )
        if choice == .uploadLocal {
            await drainPendingMutations()
        }
    }

    func drainPendingMutations() async {
        guard stateStore.isSyncEnabled, !stateStore.hasPendingServerDataMutation else { return }
        await dependencies.syncRepository.drainPendingMutations()
    }

    func removeKnownHostIfUnused(
        for server: Server,
        excluding deletedServerIDs: Set<UUID> = []
    ) {
        let isStillUsed = stateStore.servers.contains {
            !deletedServerIDs.contains($0.id)
                && $0.id != server.id
                && $0.host == server.host
                && $0.port == server.port
        }
        guard !isStillUsed else { return }
        dependencies.knownHosts.remove(host: server.host, port: server.port)
    }

    @discardableResult
    private func beginLoadingIfNeeded() -> Task<Void, Never>? {
        if let activeLoad {
            return activeLoad.task
        }

        guard stateStore.ambiguousCloudRecovery == nil else {
            logger.info("Automatic CloudKit load is paused for a recovery decision")
            return nil
        }

        guard stateStore.isSyncEnabled else {
            logger.info("iCloud sync disabled; using local data only")
            stateStore.refreshFreePlanGeneration(
                persistCurrentIfNeeded: true,
                reason: "local_only"
            )
            return nil
        }

        let operationID = stateStore.startLoading(operationID: dependencies.makeID())
        let generation = LoadGeneration()
        let remoteRepository = dependencies.remoteRepository
        let shouldForceFullFetch = stateStore.shouldForceRemoteFullFetchForBootstrap
        let task = Task { [weak self, remoteRepository] in
            do {
                let changes = try await remoteRepository.fetchServerChanges(
                    forceFullFetch: shouldForceFullFetch
                )
                guard !Task.isCancelled else { return }
                try await self?.completeLoad(
                    changes,
                    operationID: operationID,
                    generation: generation
                )
            } catch is CancellationError {
                self?.finishCancelledLoad(
                    operationID: operationID,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failLoad(
                    error,
                    operationID: operationID,
                    generation: generation
                )
            }
        }
        activeLoad = ActiveLoad(
            operationID: operationID,
            generation: generation,
            task: task
        )
        return task
    }

    private func invalidateActiveLoad() {
        guard let activeLoad else { return }
        self.activeLoad = nil
        activeLoad.task.cancel()
        stateStore.finishLoading(operationID: activeLoad.operationID)
    }

    private func acceptsLoad(_ generation: LoadGeneration) -> Bool {
        stateStore.isSyncEnabled && activeLoad?.generation === generation
    }

    private func completeLoad(
        _ fetchedChanges: ServerRemoteChanges,
        operationID: UUID,
        generation: LoadGeneration
    ) async throws {
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        let pendingBootstrapWorkspaceID = stateStore.transientBootstrapWorkspaceID
        var mustRestorePersistedCollections = true
        var mustRestorePendingBootstrapWorkspaceID = true
        defer {
            if mustRestorePersistedCollections {
                stateStore.restorePersistedCollections()
            }
            if mustRestorePendingBootstrapWorkspaceID {
                stateStore.restorePendingBootstrapWorkspaceID(
                    pendingBootstrapWorkspaceID
                )
            }
        }
        try resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(fetchedChanges)
        guard let backfillResult = try await backfillMissingLocalRecordsIfNeeded(
            for: fetchedChanges,
            generation: generation
        ) else { return }
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        let changes = backfillResult.changes

        let pendingMutations = try dependencies.syncRepository.pendingServerMutations()
        if stateStore.automaticFullFetchNeedsRecovery(
            changes,
            pendingMutations: pendingMutations
        ) {
            try stateStore.preserveAmbiguousCloudRecoveryBackup()
            throw AmbiguousCloudRecoveryError.fullFetchNeedsDecision
        }

        logger.info(
            "CloudKit returned \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
        )

        let deletedServers = serversDeletedByIncrementalChanges(changes)
        stateStore.applyRemoteChanges(
            changes,
            canReplaceLocalState: backfillResult.canReplaceLocalState
        )
        try reconcilePendingServerAndWorkspaceUpsertsAgainstRemote(changes)
        try applyPendingSyncOverlay()
        _ = stateStore.reconcilePendingBootstrapWorkspaceState()
        try repairOrphanedServers()

        guard !Task.isCancelled, acceptsLoad(generation) else { return }

        do {
            try stateStore.persistCurrentCollectionsForRemoteAcceptance()
        } catch {
            stateStore.restorePersistedCollections()
            mustRestorePersistedCollections = false
            await failLoad(error, operationID: operationID, generation: generation)
            return
        }
        mustRestorePersistedCollections = false
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "cloudkit_load"
        )
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        do {
            try dependencies.remoteRepository.acceptServerChanges(changes.checkpoint)
        } catch {
            await failLoad(error, operationID: operationID, generation: generation)
            return
        }
        mustRestorePendingBootstrapWorkspaceID = false
        removeKnownHostsDeletedByIncrementalChanges(
            changes,
            deletedServers: deletedServers
        )

        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        await drainPendingMutations()
        guard !Task.isCancelled, acceptsLoad(generation) else { return }

        logger.info(
            "Loaded \(self.stateStore.workspaces.count) workspaces and \(self.stateStore.servers.count) servers from CloudKit"
        )
        finishActiveLoad(operationID: operationID, generation: generation)
    }

    private func clearAmbiguousCloudRecoveryIfNeeded() throws {
        if stateStore.ambiguousCloudRecovery != nil {
            try stateStore.clearAmbiguousCloudRecovery()
        }
    }

    private func failLoad(
        _ error: Error,
        operationID: UUID,
        generation: LoadGeneration
    ) async {
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
        logger.info(
            "Using local data: \(self.stateStore.workspaces.count) workspaces and \(self.stateStore.servers.count) servers"
        )

        if dependencies.remoteRepository.isAvailable && dependencies.isRemoteSchemaError(error) {
            logger.info("Schema error detected, attempting to initialize schema...")
            await initializeRemoteSchema(generation: generation)
        }
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        activeLoad = nil
        stateStore.failLoading(
            operationID: operationID,
            message: error.localizedDescription
        )
    }

    private func finishCancelledLoad(
        operationID: UUID,
        generation: LoadGeneration
    ) {
        guard activeLoad?.generation === generation else { return }
        activeLoad = nil
        stateStore.finishLoading(operationID: operationID)
    }

    private func finishActiveLoad(
        operationID: UUID,
        generation: LoadGeneration
    ) {
        guard acceptsLoad(generation) else { return }
        activeLoad = nil
        stateStore.finishLoading(operationID: operationID)
    }

    private func backfillMissingLocalRecordsIfNeeded(
        for changes: ServerRemoteChanges,
        generation: LoadGeneration
    ) async throws -> FullFetchBackfillResult? {
        guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
        guard changes.isFullFetch, dependencies.remoteRepository.isAvailable else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        let cloudWorkspaceIDs = Set(changes.workspaces.map(\.id))
        let cloudServerIDs = Set(changes.servers.map(\.id))
        let pendingMutations = try dependencies.syncRepository.pendingServerMutations()
        let missingCandidates = ServerStateStore.backfillCandidates(
            pendingMutations: pendingMutations,
            cloudWorkspaceIDs: cloudWorkspaceIDs,
            cloudServerIDs: cloudServerIDs,
            deletedWorkspaceIDs: Set(changes.deletedWorkspaceIDs),
            deletedServerIDs: Set(changes.deletedServerIDs)
        )
        let missingWorkspaces = missingCandidates.workspaces
        let missingServers = missingCandidates.servers

        guard !missingWorkspaces.isEmpty || !missingServers.isEmpty else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        logger.warning(
            "CloudKit full fetch is missing \(missingWorkspaces.count) pending workspaces and \(missingServers.count) pending servers; attempting explicit pending-upsert recovery"
        )

        var uploadedWorkspaces: [Workspace] = []
        for workspace in missingWorkspaces {
            guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
            do {
                try await dependencies.remoteRepository.saveWorkspace(workspace)
                guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
                uploadedWorkspaces.append(workspace)
            } catch is CancellationError {
                return nil
            } catch {
                guard acceptsLoad(generation) else { return nil }
                logger.warning(
                    "Failed to backfill workspace \(workspace.name): \(error.localizedDescription)"
                )
            }
        }

        var knownWorkspaceIDs = cloudWorkspaceIDs
        knownWorkspaceIDs.formUnion(uploadedWorkspaces.map(\.id))

        var uploadedServers: [Server] = []
        for server in missingServers {
            guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
            guard knownWorkspaceIDs.contains(server.workspaceId) else {
                logger.warning(
                    "Skipping server backfill for \(server.name) because workspace \(server.workspaceId) is unavailable in CloudKit"
                )
                continue
            }

            do {
                try await dependencies.remoteRepository.saveServer(server)
                guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
                uploadedServers.append(server)
            } catch is CancellationError {
                return nil
            } catch {
                guard acceptsLoad(generation) else { return nil }
                logger.warning(
                    "Failed to backfill server \(server.name): \(error.localizedDescription)"
                )
            }
        }

        let backfillCompleted = uploadedWorkspaces.count == missingWorkspaces.count
            && uploadedServers.count == missingServers.count

        return FullFetchBackfillResult(
            changes: ServerRemoteChanges(
                servers: changes.servers + uploadedServers,
                workspaces: changes.workspaces + uploadedWorkspaces,
                deletedServerIDs: changes.deletedServerIDs,
                deletedWorkspaceIDs: changes.deletedWorkspaceIDs,
                isFullFetch: changes.isFullFetch,
                checkpoint: changes.checkpoint
            ),
            canReplaceLocalState: backfillCompleted
        )
    }

    private func initializeRemoteSchema(generation: LoadGeneration) async {
        logger.info("Attempting to initialize CloudKit schema by pushing local data...")

        for workspace in stateStore.workspaces {
            guard !Task.isCancelled, acceptsLoad(generation) else { return }
            do {
                try await dependencies.remoteRepository.saveWorkspace(workspace)
                guard !Task.isCancelled, acceptsLoad(generation) else { return }
                logger.info("Pushed workspace to CloudKit: \(workspace.name)")
            } catch is CancellationError {
                return
            } catch {
                guard acceptsLoad(generation) else { return }
                logger.error(
                    "Failed to push workspace \(workspace.name): \(error.localizedDescription)"
                )
            }
        }

        for server in stateStore.servers {
            guard !Task.isCancelled, acceptsLoad(generation) else { return }
            do {
                try await dependencies.remoteRepository.saveServer(server)
                guard !Task.isCancelled, acceptsLoad(generation) else { return }
                logger.info("Pushed server to CloudKit: \(server.name)")
            } catch is CancellationError {
                return
            } catch {
                guard acceptsLoad(generation) else { return }
                logger.error(
                    "Failed to push server \(server.name): \(error.localizedDescription)"
                )
            }
        }

        logger.info("CloudKit schema initialization complete")
    }

    private func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(
        _ changes: ServerRemoteChanges
    ) throws {
        guard let workspace = stateStore.takePendingBootstrapWorkspaceForAuthoritativeEmptyFetch(changes) else {
            return
        }
        try dependencies.syncRepository.enqueueServerDataMutations([
            ServerPendingMutation(
                id: dependencies.makeID(),
                payload: .workspaceUpsert(workspace),
                createdAt: dependencies.now()
            )
        ])
        logger.info(
            "Promoted pending bootstrap workspace after authoritative CloudKit fetch returned no workspaces"
        )
    }

    private func applyPendingSyncOverlay() throws {
        stateStore.applyPendingSyncOverlay(
            try dependencies.syncRepository.pendingServerMutations()
        )
    }

    private func reconcilePendingServerAndWorkspaceUpsertsAgainstRemote(
        _ changes: ServerRemoteChanges
    ) throws {
        let snapshot = try dependencies.syncRepository.pendingServerMutations()
        let fetchedServersByID = Dictionary(
            uniqueKeysWithValues: changes.servers.map { ($0.id, $0) }
        )
        let fetchedWorkspacesByID = Dictionary(
            uniqueKeysWithValues: changes.workspaces.map { ($0.id, $0) }
        )

        for mutation in snapshot {
            switch mutation.payload {
            case .serverUpsert(let pendingServer):
                guard let fetchedServer = fetchedServersByID[pendingServer.id],
                      fetchedServer.updatedAt >= pendingServer.updatedAt else {
                    continue
                }
                try dependencies.syncRepository.removePendingServerMutation(mutation.id)
            case .workspaceUpsert(let pendingWorkspace):
                guard let fetchedWorkspace = fetchedWorkspacesByID[pendingWorkspace.id],
                      fetchedWorkspace.updatedAt >= pendingWorkspace.updatedAt else {
                    continue
                }
                try dependencies.syncRepository.removePendingServerMutation(mutation.id)
            case .serverDelete, .workspaceDelete:
                continue
            }
        }
    }

    private var serverDataMutationTransaction: ServerDataMutationTransaction {
        stateStore.makeServerDataMutationTransaction(
            mutationQueue: dependencies.syncRepository,
            credentials: dependencies.credentialRepository
        )
    }

    private enum ServerDataMutationRecoveryResult: Equatable {
        case none
        case complete
        case pending
    }

    private func recoverPendingServerDataMutation() -> ServerDataMutationRecoveryResult {
        do {
            guard let journal = try serverDataMutationTransaction.resumePending() else {
                stateStore.restorePersistedCollections()
                return .none
            }
            if journal.presentsResultingState {
                applyCommittedServerDataMutation(journal.plan)
            }
            guard journal.phase == .complete else {
                logger.error("Server data mutation recovery remains pending")
                return .pending
            }
            return .complete
        } catch {
            logger.error("Could not resume server data mutation: \(error.localizedDescription)")
            return .pending
        }
    }

    private func applyCommittedServerDataMutation(_ plan: ServerDataMutationPlan) {
        let deletedServerIDs = Set(plan.deletedServers.map(\.id))
        for server in plan.deletedServers {
            removeKnownHostIfUnused(for: server, excluding: deletedServerIDs)
        }
        stateStore.applyCommittedServerDataMutation(plan)
    }

    private func removeKnownHostsDeletedByIncrementalChanges(
        _ changes: ServerRemoteChanges,
        deletedServers: [Server]
    ) {
        let deletedServerIDs = Set(changes.deletedServerIDs)
        for server in deletedServers {
            removeKnownHostIfUnused(for: server, excluding: deletedServerIDs)
        }
    }

    private func serversDeletedByIncrementalChanges(
        _ changes: ServerRemoteChanges
    ) -> [Server] {
        let deletedServerIDs = Set(changes.deletedServerIDs)
        return stateStore.servers.filter { deletedServerIDs.contains($0.id) }
    }

    private func repairOrphanedServers() throws {
        let repair = stateStore.repairOrphanedServers(at: dependencies.now())
        guard repair.workspace != nil || !repair.servers.isEmpty else { return }

        if stateStore.isSyncEnabled {
            let createdAt = dependencies.now()
            var mutations: [ServerPendingMutation] = []
            if let workspace = repair.workspace {
                mutations.append(
                    ServerPendingMutation(
                        id: dependencies.makeID(),
                        payload: .workspaceUpsert(workspace),
                        createdAt: createdAt
                    )
                )
                logger.warning(
                    "Created repair workspace '\(workspace.name)' to recover orphaned servers"
                )
            }
            mutations += repair.servers.enumerated().map { index, server in
                ServerPendingMutation(
                    id: dependencies.makeID(),
                    payload: .serverUpsert(server),
                    createdAt: createdAt.addingTimeInterval(TimeInterval(index + 1))
                )
            }
            try dependencies.syncRepository.enqueueServerDataMutations(mutations)
        }
        logger.warning("Repaired \(repair.servers.count) orphaned servers")
    }
}

private enum AuthoritativeServerResyncError: LocalizedError {
    case remoteUnavailable
    case incompleteSnapshot

    var errorDescription: String? {
        switch self {
        case .remoteUnavailable:
            return "iCloud is not available for a full server data refresh."
        case .incompleteSnapshot:
            return "iCloud did not return a complete server data snapshot."
        }
    }
}
