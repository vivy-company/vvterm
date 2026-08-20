import Foundation

@MainActor
protocol ServerRemoteRepository: AnyObject {
    var isAvailable: Bool { get }
    func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges
    func acceptServerChanges(_ checkpoint: ServerRemoteChangeCheckpoint) throws
    func saveServer(_ server: Server) async throws
    func saveWorkspace(_ workspace: Workspace) async throws
}

@MainActor
protocol ServerRemoteMutationClient: AnyObject {
    func saveServer(_ server: Server) async throws
    func deleteServer(_ server: Server) async throws
    func saveWorkspace(_ workspace: Workspace) async throws
    func deleteWorkspace(_ workspace: Workspace) async throws
}

@MainActor
protocol ServerSyncRepository:
    ServerDataMutationEnqueuing,
    AnyObject {
    func pendingServerMutations() throws -> [ServerPendingMutation]
    func clearPendingServerAndWorkspaceMutations() throws
    func removePendingServerMutation(_ mutationID: UUID) throws
    func drainPendingMutations() async
}

@MainActor
protocol ServerManagerCredentialRepository:
    ServerCredentialTransactionRepository,
    ServerMutationCredentialTransacting,
    AnyObject {
    func deleteCredentials(for serverId: UUID) throws
}

nonisolated enum ServerProtectedAction: Equatable, Sendable {
    case delete
}

@MainActor
protocol ProtectedServerActionAuthorizing: AnyObject {
    func authorize(
        _ server: Server,
        for action: ServerProtectedAction
    ) async -> Bool
}

@MainActor
protocol ServerKnownHostRepository: AnyObject {
    func remove(host: String, port: Int)
}

@MainActor
protocol FreePlanAssignmentTracking: AnyObject {
    func trackFreePlanGenerationAssigned(
        generation: String,
        serverCount: Int,
        reason: String
    )
}

@MainActor
struct ServerManagerDependencies {
    let stateStore: ServerStateStore
    let remoteSyncCoordinator: ServerRemoteSyncCoordinator
    let syncRepository: any ServerSyncRepository
    let credentialRepository: any ServerManagerCredentialRepository
    let actionAuthorizer: any ProtectedServerActionAuthorizing
    let now: () -> Date
    let makeID: () -> UUID

    init(
        stateStore: ServerStateStore,
        remoteRepository: any ServerRemoteRepository,
        syncRepository: any ServerSyncRepository,
        credentialRepository: any ServerManagerCredentialRepository,
        actionAuthorizer: any ProtectedServerActionAuthorizing,
        knownHosts: any ServerKnownHostRepository,
        isRemoteSchemaError: @escaping (Error) -> Bool,
        now: @escaping () -> Date,
        makeID: @escaping () -> UUID
    ) {
        self.stateStore = stateStore
        self.syncRepository = syncRepository
        self.credentialRepository = credentialRepository
        self.actionAuthorizer = actionAuthorizer
        self.now = now
        self.makeID = makeID
        remoteSyncCoordinator = ServerRemoteSyncCoordinator(
            dependencies: ServerRemoteSyncCoordinatorDependencies(
                stateStore: stateStore,
                remoteRepository: remoteRepository,
                syncRepository: syncRepository,
                credentialRepository: credentialRepository,
                knownHosts: knownHosts,
                isRemoteSchemaError: isRemoteSchemaError,
                now: now,
                makeID: makeID
            )
        )
    }
}
