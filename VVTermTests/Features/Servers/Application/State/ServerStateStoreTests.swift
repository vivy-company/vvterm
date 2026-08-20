import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerStateStoreTests {
    @Test
    func bootstrapUsesTheInjectedDefaultWorkspaceName() {
        let repository = ServerStateLocalRepository(servers: [], workspaces: [])
        let preferences = ServerStatePreferences()
        preferences.didBootstrapDefaultWorkspace = false
        preferences.hasSeenWelcome = false

        let store = ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: repository,
                preferences: preferences,
                freePlanTracker: ServerStateFreePlanTracker(),
                isSyncEnabled: { false },
                now: { Date(timeIntervalSinceReferenceDate: 1_000) },
                makeID: {
                    UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
                },
                defaultWorkspaceName: { "Mes serveurs" },
                canonicalDefaultWorkspaceNames: { ["My Servers", "Mes serveurs"] }
            )
        )

        #expect(store.workspaces.map(\.name) == ["Mes serveurs"])
        #expect(repository.workspaces.map(\.name) == ["Mes serveurs"])
    }

    @Test
    func twoStoresKeepMutationAndPersistenceIsolated() throws {
        let firstWorkspace = makeWorkspace(id: "10000000-0000-0000-0000-000000000001")
        let secondWorkspace = makeWorkspace(id: "10000000-0000-0000-0000-000000000002")
        let firstRepository = ServerStateLocalRepository(
            servers: [],
            workspaces: [firstWorkspace]
        )
        let secondRepository = ServerStateLocalRepository(
            servers: [],
            workspaces: [secondWorkspace]
        )
        let firstStore = makeStore(repository: firstRepository)
        let secondStore = makeStore(repository: secondRepository)
        let server = makeServer(workspaceID: firstWorkspace.id)

        _ = try firstStore.commitMutation(
            .insertServer(server),
            now: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        #expect(firstStore.servers.map(\.id) == [server.id])
        #expect(firstRepository.servers.map(\.id) == [server.id])
        #expect(secondStore.servers.isEmpty)
        #expect(secondRepository.servers.isEmpty)
        #expect(firstStore.snapshot != secondStore.snapshot)
    }

    @Test
    func failedPersistenceDoesNotPublishPlannedMutation() {
        let workspace = makeWorkspace(id: "10000000-0000-0000-0000-000000000003")
        let repository = ServerStateLocalRepository(servers: [], workspaces: [workspace])
        repository.persistError = ServerStateStoreTestError.persistence
        let store = makeStore(repository: repository)
        let originalSnapshot = store.snapshot

        #expect(throws: ServerStateStoreTestError.self) {
            _ = try store.commitMutation(
                .insertServer(makeServer(workspaceID: workspace.id)),
                now: Date(timeIntervalSinceReferenceDate: 2_000)
            )
        }

        #expect(store.snapshot == originalSnapshot)
        #expect(repository.persistAttempts == 1)
    }

    @Test
    func workspaceCreateCandidateUsesInjectedIdentityAndTime() {
        let existing = makeWorkspace(id: "10000000-0000-0000-0000-000000000004")
        let repository = ServerStateLocalRepository(servers: [], workspaces: [existing])
        let id = UUID(uuidString: "90000000-0000-0000-0000-000000000004")!
        let date = Date(timeIntervalSinceReferenceDate: 4_000)
        let store = makeStore(
            repository: repository,
            now: { date },
            makeID: { id }
        )

        let candidate = store.makeWorkspaceSaveCandidate(
            editing: nil,
            name: "Created",
            colorHex: "#123456"
        )

        #expect(candidate.id == id)
        #expect(candidate.name == "Created")
        #expect(candidate.colorHex == "#123456")
        #expect(candidate.icon == nil)
        #expect(candidate.order == 1)
        #expect(candidate.environments == ServerEnvironment.builtInEnvironments)
        #expect(candidate.lastSelectedEnvironmentId == nil)
        #expect(candidate.lastSelectedServerId == nil)
        #expect(candidate.createdAt == date)
        #expect(candidate.updatedAt == date)
    }

    @Test
    func workspaceEditCandidatePreservesExistingFieldsAndUsesInjectedTime() {
        let environment = ServerEnvironment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Custom",
            shortName: "Cust",
            colorHex: "#654321"
        )
        let selectedServerID = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 400)
        let existing = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            name: "Existing",
            colorHex: "#000000",
            icon: "folder",
            order: 7,
            environments: [environment],
            lastSelectedEnvironmentId: environment.id,
            lastSelectedServerId: selectedServerID,
            createdAt: createdAt,
            updatedAt: .distantPast
        )
        let repository = ServerStateLocalRepository(servers: [], workspaces: [existing])
        let updatedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        var makeIDCount = 0
        let store = makeStore(
            repository: repository,
            now: { updatedAt },
            makeID: {
                makeIDCount += 1
                return UUID(uuidString: "90000000-0000-0000-0000-000000000005")!
            }
        )

        let candidate = store.makeWorkspaceSaveCandidate(
            editing: existing,
            name: "Edited",
            colorHex: "#ABCDEF"
        )

        #expect(candidate.id == existing.id)
        #expect(candidate.name == "Edited")
        #expect(candidate.colorHex == "#ABCDEF")
        #expect(candidate.icon == existing.icon)
        #expect(candidate.order == existing.order)
        #expect(candidate.environments == existing.environments)
        #expect(candidate.lastSelectedEnvironmentId == existing.lastSelectedEnvironmentId)
        #expect(candidate.lastSelectedServerId == existing.lastSelectedServerId)
        #expect(candidate.createdAt == createdAt)
        #expect(candidate.updatedAt == updatedAt)
        #expect(makeIDCount == 0)
    }

    @Test
    func unreadableLocalCollectionIssueBelongsToItsStoreAndCanBeDismissed() {
        let issue = ServerLocalStorageIssue(
            collection: .servers,
            quarantineKey: "servers.quarantine"
        )
        let unreadableRepository = ServerStateLocalRepository(
            serverLoadResult: .unreadable(issue),
            workspaceLoadResult: .missing
        )
        let healthyRepository = ServerStateLocalRepository(servers: [], workspaces: [])
        let unreadableStore = makeStore(repository: unreadableRepository)
        let healthyStore = makeStore(repository: healthyRepository)

        #expect(unreadableStore.localStorageIssues == [issue])
        #expect(healthyStore.localStorageIssues.isEmpty)

        unreadableStore.dismissLocalStorageIssues()

        #expect(unreadableStore.localStorageIssues.isEmpty)
        #expect(healthyStore.localStorageIssues.isEmpty)
    }

    private func makeStore(
        repository: ServerStateLocalRepository,
        now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 1_000) },
        makeID: @escaping () -> UUID = {
            UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
        }
    ) -> ServerStateStore {
        ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: repository,
                preferences: ServerStatePreferences(),
                freePlanTracker: ServerStateFreePlanTracker(),
                isSyncEnabled: { false },
                now: now,
                makeID: makeID,
                defaultWorkspaceName: { "My Servers" },
                canonicalDefaultWorkspaceNames: { ["My Servers"] }
            )
        )
    }

    private func makeWorkspace(id: String) -> Workspace {
        Workspace(
            id: UUID(uuidString: id)!,
            name: "Workspace",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID) -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspaceID,
            name: "Server",
            host: "server.example.test",
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

@MainActor
private final class ServerStateLocalRepository: ServerLocalRepository {
    var servers: [Server]
    var workspaces: [Workspace]
    var persistError: Error?
    var persistAttempts = 0
    var serverMutationJournal: ServerDataMutationJournal?
    var ambiguousCloudRecoveryBackup: AmbiguousCloudRecoveryBackup?

    private let serverLoadResult: ServerLocalLoadResult<[Server]>?
    private let workspaceLoadResult: ServerLocalLoadResult<[Workspace]>?

    init(servers: [Server], workspaces: [Workspace]) {
        self.servers = servers
        self.workspaces = workspaces
        serverLoadResult = nil
        workspaceLoadResult = nil
    }

    init(
        serverLoadResult: ServerLocalLoadResult<[Server]>,
        workspaceLoadResult: ServerLocalLoadResult<[Workspace]>
    ) {
        servers = []
        workspaces = []
        self.serverLoadResult = serverLoadResult
        self.workspaceLoadResult = workspaceLoadResult
    }

    func loadSnapshot() -> ServerLocalRepositorySnapshot {
        ServerLocalRepositorySnapshot(
            servers: serverLoadResult ?? .loaded(servers),
            workspaces: workspaceLoadResult ?? .loaded(workspaces)
        )
    }

    func persist(servers: [Server], workspaces: [Workspace]) throws {
        persistAttempts += 1
        if serverMutationJournal != nil { throw ServerLocalStoreError.serverDataMutationPending }
        if let persistError { throw persistError }
        self.servers = servers
        self.workspaces = workspaces
    }

    func clearServerData() throws {
        if serverMutationJournal != nil { throw ServerLocalStoreError.serverDataMutationPending }
        servers = []
        workspaces = []
    }

    func loadAmbiguousCloudRecoveryBackup() throws -> AmbiguousCloudRecoveryBackup? {
        ambiguousCloudRecoveryBackup
    }
    func storeAmbiguousCloudRecoveryBackup(_ backup: AmbiguousCloudRecoveryBackup) throws {
        if ambiguousCloudRecoveryBackup == nil {
            ambiguousCloudRecoveryBackup = backup
        }
    }
    func clearAmbiguousCloudRecoveryBackup() throws {
        ambiguousCloudRecoveryBackup = nil
    }

    func loadServerDataMutationJournal() throws -> ServerDataMutationJournal? {
        serverMutationJournal
    }
    func storeServerDataMutationJournal(
        _ journal: ServerDataMutationJournal
    ) throws {
        serverMutationJournal = journal
    }
    func materializeServerDataMutation(_ plan: ServerDataMutationPlan) throws {
        if let persistError { throw persistError }
        servers = plan.resultingServers
        workspaces = plan.resultingWorkspaces
    }
    func clearServerDataMutationJournal() throws {
        serverMutationJournal = nil
    }

}

@MainActor
private final class ServerStatePreferences: ServerManagerPreferences {
    var didBootstrapDefaultWorkspace = true
    var hasSeenWelcome = true
    var freePlanGeneration: FreePlanGeneration? = .currentOneServer
    var pendingBootstrapWorkspaceID: UUID?
}

@MainActor
private final class ServerStateFreePlanTracker: FreePlanAssignmentTracking {
    func trackFreePlanGenerationAssigned(
        generation: String,
        serverCount: Int,
        reason: String
    ) {}
}

private enum ServerStateStoreTestError: Error {
    case persistence
}
