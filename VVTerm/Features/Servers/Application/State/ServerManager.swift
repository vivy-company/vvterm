import Foundation
import Combine
import os.log

@MainActor
final class ServerManager: ObservableObject, ServerMutationRepository {
    let stateStore: ServerStateStore

    var servers: [Server] {
        stateStore.servers
    }

    var workspaces: [Workspace] {
        stateStore.workspaces
    }

    var freePlanGeneration: FreePlanGeneration {
        stateStore.freePlanGeneration
    }

    private let dependencies: ServerManagerDependencies
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    private var stateObservation: AnyCancellable?

    private var remoteSyncCoordinator: ServerRemoteSyncCoordinator {
        dependencies.remoteSyncCoordinator
    }

    init(
        dependencies: ServerManagerDependencies,
        startsAutomatically: Bool = true
    ) {
        self.dependencies = dependencies
        stateStore = dependencies.stateStore
        stateObservation = stateStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if startsAutomatically {
            remoteSyncCoordinator.startAutomaticLoad()
        }
    }

    // MARK: - Pending Remote Sync

    /// Clear all local data and re-download from CloudKit
    func clearLocalDataAndResync() async throws {
        try await remoteSyncCoordinator.clearLocalDataAndResync()
    }

    func resolveAmbiguousCloudRecovery(
        _ choice: AmbiguousCloudRecoveryChoice
    ) async throws {
        try await remoteSyncCoordinator.resolveAmbiguousCloudRecovery(choice)
    }

    // MARK: - Data Loading

    func loadData() async {
        await remoteSyncCoordinator.loadData()
    }

    func handleSyncDisabled() {
        remoteSyncCoordinator.handleSyncDisabled()
    }

    // MARK: - Server CRUD

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {
        switch mutation {
        case .create:
            guard stateStore.canAddServer(hasProAccess: hasProAccess) else {
                throw VVTermError.proRequired(.unlimitedServers)
            }
        case .update(let server):
            guard stateStore.server(withID: server.id) != nil else {
                throw VVTermError.serverNotFound
            }
        }
    }

    func apply(
        _ mutation: ServerMutation,
        credentials: ServerCredentials
    ) async throws -> Server {
        let command: ServerMutationCommand
        switch mutation {
        case .create(let server):
            command = .insertServer(server)

        case .update(let server):
            command = .updateServer(server)
        }
        let previousServers = servers
        let previousWorkspaces = workspaces
        let result = try stateStore.planMutation(
            command,
            now: dependencies.now()
        )

        guard case .serverUpsert(let savedServer) = result.effect else {
            preconditionFailure("A server save command must produce a server upsert")
        }
        let previousServer: Server?
        switch mutation {
        case .create:
            previousServer = nil
        case .update:
            previousServer = previousServers.first { $0.id == savedServer.id }
        }
        let transactionID = dependencies.makeID()
        let plan = ServerDataMutationPlan(
            id: transactionID,
            previousServers: previousServers,
            previousWorkspaces: previousWorkspaces,
            resultingServers: result.servers,
            resultingWorkspaces: result.workspaces,
            pendingMutation: ServerPendingMutation(
                id: dependencies.makeID(),
                payload: .serverUpsert(savedServer),
                createdAt: dependencies.now()
            ),
            credentialAction: .replace(
                transactionID: transactionID,
                previousServer: previousServer,
                server: savedServer
            )
        )
        let journal = try serverDataMutationTransaction.commitSave(
            plan,
            credentials: credentials
        )
        if journal.presentsResultingState {
            stateStore.applyCommittedServerDataMutation(plan)
        }
        guard journal.phase == .complete else {
            throw VVTermError.serverDataMutationRecoveryPending
        }
        await remoteSyncCoordinator.drainPendingMutations()

        if case .create = mutation {
            stateStore.promotePendingBootstrapWorkspaceIfNeeded(
                for: savedServer.workspaceId,
                reason: "adding a server"
            )
        }
        let action: String
        switch mutation {
        case .create:
            action = "Added"
        case .update:
            action = "Updated"
        }
        logger.info("\(action) server: \(savedServer.name)")
        return savedServer
    }

    func deleteServer(_ server: Server) async throws {
        guard let storedServer = servers.first(where: { $0.id == server.id }) else { return }
        guard await dependencies.actionAuthorizer.authorize(
            storedServer,
            for: .delete
        ) else {
            throw VVTermError.authorizationRequired
        }

        try await deleteServerData(storedServer)
    }

    private func deleteServerData(_ server: Server) async throws {
        let result = try stateStore.planMutation(
            .deleteServer(server.id),
            now: dependencies.now()
        )
        let plan = ServerDataMutationPlan(
            id: dependencies.makeID(),
            previousServers: servers,
            previousWorkspaces: workspaces,
            resultingServers: result.servers,
            resultingWorkspaces: result.workspaces,
            pendingMutation: ServerPendingMutation(
                id: dependencies.makeID(),
                payload: .serverDelete(server),
                createdAt: dependencies.now()
            ),
            credentialAction: .delete([server])
        )
        let journal = try serverDataMutationTransaction.commit(plan)
        if journal.presentsResultingState {
            stateStore.applyCommittedServerDataMutation(plan)
            remoteSyncCoordinator.removeKnownHostIfUnused(for: server)
        }
        guard journal.phase == .complete else {
            throw VVTermError.serverDataMutationRecoveryPending
        }
        await remoteSyncCoordinator.drainPendingMutations()
        logger.info("Deleted server: \(server.name)")
    }

    private var serverDataMutationTransaction: ServerDataMutationTransaction {
        stateStore.makeServerDataMutationTransaction(
            mutationQueue: dependencies.syncRepository,
            credentials: dependencies.credentialRepository
        )
    }

    func updateLastConnected(for server: Server) async throws {
        try stateStore.updateLastConnected(for: server.id, at: dependencies.now())
    }

    // MARK: - Workspace CRUD

    func addWorkspace(_ workspace: Workspace, hasProAccess: Bool) async throws {
        guard stateStore.canAddWorkspace(hasProAccess: hasProAccess) else {
            throw VVTermError.proRequired(.unlimitedWorkspaces)
        }

        let previousServers = servers
        let previousWorkspaces = workspaces
        let result = try stateStore.planMutation(
            .insertWorkspace(workspace),
            now: dependencies.now()
        )
        guard case .workspaceUpsert(let savedWorkspace) = result.effect else {
            preconditionFailure("A workspace insert must produce a workspace upsert")
        }
        let plan = ServerDataMutationPlan(
            id: dependencies.makeID(),
            kind: .workspaceUpsert(savedWorkspace.id),
            previousServers: previousServers,
            previousWorkspaces: previousWorkspaces,
            resultingServers: result.servers,
            resultingWorkspaces: result.workspaces,
            pendingMutations: [
                ServerPendingMutation(
                    id: dependencies.makeID(),
                    payload: .workspaceUpsert(savedWorkspace),
                    createdAt: dependencies.now()
                )
            ]
        )
        try commitServerDataMutation(plan)
        stateStore.clearPendingBootstrapWorkspace(reason: "adding a workspace")
        await remoteSyncCoordinator.drainPendingMutations()
        logger.info("Added workspace: \(workspace.name)")
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
        let previousServers = servers
        let previousWorkspaces = workspaces
        let result = try stateStore.planMutation(
            .updateWorkspace(workspace),
            now: dependencies.now()
        )
        guard case .workspaceUpsert(let savedWorkspace) = result.effect else {
            preconditionFailure("A workspace update must produce a workspace upsert")
        }
        let plan = ServerDataMutationPlan(
            id: dependencies.makeID(),
            kind: .workspaceUpsert(savedWorkspace.id),
            previousServers: previousServers,
            previousWorkspaces: previousWorkspaces,
            resultingServers: result.servers,
            resultingWorkspaces: result.workspaces,
            pendingMutations: [
                ServerPendingMutation(
                    id: dependencies.makeID(),
                    payload: .workspaceUpsert(savedWorkspace),
                    createdAt: dependencies.now()
                )
            ]
        )
        try commitServerDataMutation(plan)
        stateStore.promotePendingBootstrapWorkspaceIfNeeded(
            for: workspace.id,
            reason: "updating workspace metadata"
        )
        await remoteSyncCoordinator.drainPendingMutations()
        logger.info("Updated workspace: \(workspace.name)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        let initialDeletedServers = servers.filter { $0.workspaceId == workspace.id }
        guard let plan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: servers,
            workspaces: workspaces,
            id: dependencies.makeID(),
            mutationIDs: initialDeletedServers.map { _ in dependencies.makeID() }
                + [dependencies.makeID()],
            mutationDate: dependencies.now()
        ) else {
            return
        }

        for server in plan.deletedServers where server.requiresBiometricUnlock {
            guard await dependencies.actionAuthorizer.authorize(
                server,
                for: .delete
            ) else {
                throw VVTermError.authorizationRequired
            }
        }

        let currentDeletedServers = servers.filter { $0.workspaceId == workspace.id }
        guard let currentPlan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: servers,
            workspaces: workspaces,
            id: dependencies.makeID(),
            mutationIDs: currentDeletedServers.map { _ in dependencies.makeID() }
                + [dependencies.makeID()],
            mutationDate: dependencies.now()
        ), plan.hasSameDeletionSnapshot(as: currentPlan) else {
            throw VVTermError.workspaceDeletionChanged
        }

        let dataPlan = ServerDataMutationPlan(workspaceDeletion: currentPlan)
        let journal = try serverDataMutationTransaction.commit(dataPlan)
        applyCommittedServerDataMutation(journal)
        await remoteSyncCoordinator.drainPendingMutations()

        guard journal.phase == .complete else {
            logger.error("Workspace deletion committed with pending recovery work")
            throw VVTermError.serverDataMutationRecoveryPending
        }
        logger.info("Deleted workspace: \(plan.workspace.name)")
    }

    func reorderWorkspaces(from source: IndexSet, to destination: Int) async throws {
        let reordered = try stateStore.planWorkspaceReorder(
            from: source,
            to: destination,
            at: dependencies.now()
        )
        let mutationDate = dependencies.now()
        let plan = ServerDataMutationPlan(
            id: dependencies.makeID(),
            kind: .workspaceBatchUpsert(reordered.map(\.id)),
            previousServers: servers,
            previousWorkspaces: workspaces,
            resultingServers: servers,
            resultingWorkspaces: reordered,
            pendingMutations: reordered.enumerated().map { index, workspace in
                ServerPendingMutation(
                    id: dependencies.makeID(),
                    payload: .workspaceUpsert(workspace),
                    createdAt: mutationDate.addingTimeInterval(TimeInterval(index))
                )
            }
        )
        try commitServerDataMutation(plan)
        stateStore.clearPendingBootstrapWorkspace(reason: "reordering workspaces")
        await remoteSyncCoordinator.drainPendingMutations()
        logger.info("Reordered workspaces")
    }

    // MARK: - Queries

    func servers(in workspace: Workspace, environment: ServerEnvironment?) -> [Server] {
        stateStore.servers(in: workspace, environment: environment)
    }

    func workspace(withId id: UUID?) -> Workspace? {
        stateStore.workspace(withID: id)
    }

    func server(id: UUID) -> Server? {
        stateStore.server(withID: id)
    }

    func moveServer(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil,
        hasProAccess: Bool
    ) async throws -> Server {
        guard let refreshedDestination = stateStore.workspace(withID: destination.id) else {
            throw VVTermError.moveNotAllowed(.destinationUnavailable)
        }

        if let restriction = moveRestriction(
            for: server,
            destination: refreshedDestination,
            hasProAccess: hasProAccess
        ) {
            throw restriction
        }

        let sourceWorkspace = stateStore.workspace(withID: server.workspaceId)
        let resolvedEnvironment = stateStore.resolvedEnvironment(
            for: server,
            destination: refreshedDestination,
            preferredEnvironment: preferredEnvironment
        )

        var updatedServer = server
        updatedServer.workspaceId = refreshedDestination.id
        updatedServer.environment = resolvedEnvironment

        _ = try await apply(
            .update(updatedServer),
            credentials: try dependencies.credentialRepository.getCredentials(for: server)
        )
        try await updateWorkspaceSelectionMetadataAfterMove(
            serverId: server.id,
            from: sourceWorkspace,
            to: refreshedDestination
        )

        return updatedServer
    }

    // MARK: - Pro Limits

    var freeServerLimit: Int {
        stateStore.freeServerLimit
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server, hasProAccess: Bool) -> Bool {
        stateStore.isServerLocked(server, hasProAccess: hasProAccess)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace, hasProAccess: Bool) -> Bool {
        stateStore.isWorkspaceLocked(workspace, hasProAccess: hasProAccess)
    }

    private func moveRestriction(
        for server: Server,
        destination: Workspace,
        hasProAccess: Bool
    ) -> VVTermError? {
        guard server.workspaceId != destination.id else { return nil }

        switch stateStore.moveRestriction(
            for: server,
            destination: destination,
            hasProAccess: hasProAccess
        ) {
        case nil:
            return nil
        case .lockedWorkspace:
            return VVTermError.proRequired(.moveIntoLockedWorkspace)
        case .unavailable:
            return VVTermError.moveNotAllowed(.unavailable)
        }
    }

    private func updateWorkspaceSelectionMetadataAfterMove(
        serverId: UUID,
        from sourceWorkspace: Workspace?,
        to destinationWorkspace: Workspace
    ) async throws {
        if let sourceWorkspace,
           sourceWorkspace.id != destinationWorkspace.id,
           sourceWorkspace.lastSelectedServerId == serverId {
            var updatedSource = sourceWorkspace
            updatedSource.lastSelectedServerId = nil
            try await updateWorkspace(updatedSource)
        }

        if destinationWorkspace.lastSelectedServerId != serverId {
            var updatedDestination = destinationWorkspace
            updatedDestination.lastSelectedServerId = serverId
            try await updateWorkspace(updatedDestination)
        }
    }

    func updateEnvironment(_ environment: ServerEnvironment, in workspace: Workspace) async throws -> Workspace {
        var updatedWorkspace = workspace
        if let envIndex = updatedWorkspace.environments.firstIndex(where: { $0.id == environment.id }) {
            updatedWorkspace.environments[envIndex] = environment
        } else {
            return updatedWorkspace
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = environment
            _ = try await apply(
                .update(updatedServer),
                credentials: try dependencies.credentialRepository.getCredentials(for: server)
            )
        }

        return updatedWorkspace
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace
    ) async throws -> EnvironmentDeletionResult {
        try await deleteEnvironment(environment, in: workspace, fallback: .production)
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        fallback: ServerEnvironment
    ) async throws -> EnvironmentDeletionResult {
        let affectedServerCount = servers.lazy.filter {
            $0.workspaceId == workspace.id && $0.environment.id == environment.id
        }.count
        let plan = try EnvironmentDeletionPlan(
            workspaceID: workspace.id,
            environmentID: environment.id,
            fallbackID: fallback.id,
            servers: servers,
            workspaces: workspaces,
            id: dependencies.makeID(),
            mutationIDs: (0...affectedServerCount).map { _ in dependencies.makeID() },
            mutationDate: dependencies.now()
        )
        let dataPlan = ServerDataMutationPlan(
            environmentDeletion: plan,
            previousServers: servers,
            previousWorkspaces: workspaces
        )
        let journal = try serverDataMutationTransaction.commit(dataPlan)
        applyCommittedServerDataMutation(journal)
        await remoteSyncCoordinator.drainPendingMutations()
        guard journal.phase == .complete else {
            throw VVTermError.serverDataMutationRecoveryPending
        }
        logger.info("Deleted environment: \(environment.name)")
        return EnvironmentDeletionResult(
            workspace: plan.updatedWorkspace,
            selectedEnvironment: plan.fallback
        )
    }

    func handleAppLanguageChange() {
        stateStore.handleAppLanguageChange()
    }

    private func commitServerDataMutation(_ plan: ServerDataMutationPlan) throws {
        let journal = try serverDataMutationTransaction.commit(plan)
        applyCommittedServerDataMutation(journal)
        guard journal.phase == .complete else {
            throw VVTermError.serverDataMutationRecoveryPending
        }
    }

    private func applyCommittedServerDataMutation(_ journal: ServerDataMutationJournal) {
        guard journal.presentsResultingState else { return }
        stateStore.applyCommittedServerDataMutation(journal.plan)
        let deletedServerIDs = Set(journal.plan.deletedServers.map(\.id))
        for server in journal.plan.deletedServers {
            remoteSyncCoordinator.removeKnownHostIfUnused(
                for: server,
                excluding: deletedServerIDs
            )
        }
    }
}
