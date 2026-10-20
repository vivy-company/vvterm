#if DEBUG
import Foundation

/// Exercises the normal form and save transaction with memory-only boundaries.
@MainActor
struct TeleportServerFormUITestComposition {
    let serverManager: ServerManager
    let formDependencies: ServerFormDependencies

    init(template: ServerFormDependencies) {
        let boundary = Boundary()
        let state = ServerStateStore(dependencies: ServerStateStoreDependencies(
            localRepository: boundary, preferences: boundary, freePlanTracker: boundary,
            isSyncEnabled: { false }, now: Date.init, makeID: UUID.init,
            defaultWorkspaceName: { "Teleport UI Test" }
        ))
        serverManager = ServerManager(dependencies: ServerManagerDependencies(
            stateStore: state, remoteRepository: boundary, syncRepository: boundary,
            credentialRepository: boundary, actionAuthorizer: boundary, knownHosts: boundary,
            didDeleteServerLocalData: { _ in }, isRemoteSchemaError: { _ in false },
            now: Date.init, makeID: UUID.init
        ), startsAutomatically: false)
        formDependencies = ServerFormDependencies(
            credentials: boundary, connectionTester: BoundaryProbe(),
            wakeOnLANMACAddressResolver: BoundaryProbe(), hostKeys: BoundaryProbe(),
            remoteSessionBackends: template.remoteSessionBackends,
            defaultRemoteSessionEnabled: { false },
            defaultRemoteSessionBackendIdentifier: { .tmux },
            defaultRemoteSessionStartupBehavior: { .ask },
            now: Date.init, makeID: UUID.init
        )
    }

    private nonisolated enum Failure: Error { case unexpectedExternalOperation }

    private nonisolated struct BoundaryProbe: ServerConnectionTesting, WakeOnLANMACAddressResolving, ServerHostKeyRepository {
        func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult { .cancelled }
        func resolveMACAddress(for server: Server, credentials: ServerCredentials) async throws -> WakeOnLANMACAddress {
            throw Failure.unexpectedExternalOperation
        }
        func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge? { nil }
        func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool { false }
        func reject(_ challenge: KnownHostsManager.Challenge) {}
    }

    @MainActor
    private final class Boundary: ServerLocalRepository, ServerManagerPreferences, FreePlanAssignmentTracking,
        ServerRemoteRepository, ServerSyncRepository, ServerManagerCredentialRepository,
        ServerCredentialRepository, ProtectedServerActionAuthorizing, ServerKnownHostRepository {
        private var servers: [Server] = []
        private var workspaces = [Workspace(name: "Teleport UI Test", colorHex: "#5AC8FA", order: 0)]
        private var journal: ServerDataMutationJournal?
        var hasResolvedInitialWorkspace = true
        var hasSeenWelcome: Bool { true }
        var freePlanGeneration: FreePlanGeneration? = .currentOneServer
        var isAvailable: Bool { false }

        func loadSnapshot() -> ServerLocalRepositorySnapshot {
            .init(servers: .loaded(servers), workspaces: .loaded(workspaces))
        }
        func persist(servers: [Server], workspaces: [Workspace]) throws {
            // Include the production Codable boundary when a saved form is reopened.
            self.servers = try JSONDecoder().decode([Server].self, from: JSONEncoder().encode(servers))
            self.workspaces = workspaces
        }
        func clearServerData() { servers = []; workspaces = [] }
        func loadAmbiguousCloudRecoveryBackup() -> AmbiguousCloudRecoveryBackup? { nil }
        func storeAmbiguousCloudRecoveryBackup(_ backup: AmbiguousCloudRecoveryBackup) throws { throw Failure.unexpectedExternalOperation }
        func clearAmbiguousCloudRecoveryBackup() {}
        func loadServerDataMutationJournal() -> ServerDataMutationJournal? { journal }
        func storeServerDataMutationJournal(_ journal: ServerDataMutationJournal) { self.journal = journal }
        func materializeServerDataMutation(_ plan: ServerDataMutationPlan) throws {
            try persist(servers: plan.resultingServers, workspaces: plan.resultingWorkspaces)
        }
        func clearServerDataMutationJournal() { journal = nil }
        func trackFreePlanGenerationAssigned(generation: String, serverCount: Int, reason: String) {}
        func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges { throw Failure.unexpectedExternalOperation }
        func acceptServerChanges(_ checkpoint: ServerRemoteChangeCheckpoint) throws { throw Failure.unexpectedExternalOperation }
        func saveServer(_ server: Server) async throws { throw Failure.unexpectedExternalOperation }
        func saveWorkspace(_ workspace: Workspace) async throws { throw Failure.unexpectedExternalOperation }
        func createWorkspaceIfAbsent(_ workspace: Workspace) async throws -> Workspace { throw Failure.unexpectedExternalOperation }
        func pendingServerMutations() -> [ServerPendingMutation] { [] }
        func clearPendingServerAndWorkspaceMutations() {}
        func removePendingServerMutation(_ mutationID: UUID) {}
        func drainPendingMutations() async {}
        func enqueueServerDataMutations(_ mutations: [ServerPendingMutation]) {}
        func getCredentials(for server: Server) -> ServerCredentials { ServerCredentials(serverId: server.id) }
        func storeCredentials(_ credentials: ServerCredentials, for server: Server) {}
        func deleteCredentials(for serverID: UUID) {}
        func getStoredSSHKeys() -> [SSHKeyEntry] { [] }
        func getStoredSSHKeyData(for id: UUID) -> (key: Data, passphrase: String?)? { nil }
        func prepareServerCredentialTransaction(id: UUID, previousServer: Server?, server: Server, credentials: ServerCredentials) throws {
            guard server.connectionMode == .teleport, server.authMethod == nil,
                  credentials.password == nil, credentials.privateKey == nil,
                  credentials.passphrase == nil else { throw Failure.unexpectedExternalOperation }
        }
        func commitServerCredentialTransaction(id: UUID, previousServer: Server?, server: Server) {}
        func discardServerCredentialTransaction(id: UUID) {}
        func cleanupCredentials(for server: Server) {}
        func authorize(_ server: Server, for action: ServerProtectedAction) async -> Bool { true }
        func remove(host: String, port: Int) {}
    }
}
#endif
