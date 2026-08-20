import Foundation
import Testing
@testable import VVTerm

@MainActor
struct WorkspaceDeletionTransactionTests {
    @Test
    func serverCodecDecodesTheDurableQueueShape() throws {
        let fixture = WorkspaceDeletionFixture()
        let id = UUID(uuidString: "30000000-0000-0000-0000-000000000010")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_500)
        let existingQueueMutation = PendingCloudKitMutation(
            id: id,
            payload: try .serverDelete(fixture.firstServer),
            createdAt: createdAt,
            retryCount: 4,
            lastErrorDescription: "retry"
        )

        let durableMutation = try JSONDecoder().decode(
            PendingCloudKitMutation.self,
            from: JSONEncoder().encode(existingQueueMutation)
        )
        let decodedPayloadValue = try ServerPendingCloudKitPayloadCodec.decode(
            durableMutation.payload
        )
        let decodedPayload = try #require(decodedPayloadValue)
        let decoded = ServerPendingMutation(
            id: durableMutation.id,
            payload: decodedPayload,
            createdAt: durableMutation.createdAt
        )

        #expect(
            decoded == ServerPendingMutation(
                id: id,
                payload: .serverDelete(fixture.firstServer),
                createdAt: createdAt
            )
        )
        #expect(
            try JSONDecoder().decode(
                ServerPendingMutation.self,
                from: JSONEncoder().encode(decoded)
            ) == decoded
        )
    }

    @Test
    func secondCredentialFailureKeepsOneAtomicVisibleDeletionAndDurableRetry() throws {
        let fixture = WorkspaceDeletionFixture()
        let store = TestWorkspaceDeletionStore()
        let queue = TestWorkspaceDeletionQueue()
        let cleaner = TestWorkspaceCredentialCleaner(failingServerID: fixture.secondServer.id)
        let transaction = ServerDataMutationTransaction(
            store: store,
            mutationQueue: queue,
            credentials: cleaner
        )

        let journal = try transaction.commit(ServerDataMutationPlan(workspaceDeletion: fixture.plan))

        #expect(store.materializedPlan?.resultingServers == [fixture.otherServer])
        #expect(store.materializedPlan?.resultingWorkspaces == [fixture.otherWorkspace])
        #expect(queue.enqueuedMutations.isEmpty)
        #expect(cleaner.cleanedServerIDs == [fixture.firstServer.id, fixture.secondServer.id])
        #expect(
            journal.phase == .finalizingCredentials
        )
        #expect(journal.lastFailure?.stage == .credentialFinalization)
        #expect(store.journal == journal)
    }

    @Test
    func journalPersistenceFailureDoesNotStartDeletion() {
        let fixture = WorkspaceDeletionFixture()
        let store = TestWorkspaceDeletionStore()
        store.failNextJournalWrite = true
        let queue = TestWorkspaceDeletionQueue()
        let cleaner = TestWorkspaceCredentialCleaner()
        let transaction = ServerDataMutationTransaction(
            store: store,
            mutationQueue: queue,
            credentials: cleaner
        )

        #expect(throws: TestWorkspaceDeletionError.self) {
            try transaction.commit(ServerDataMutationPlan(workspaceDeletion: fixture.plan))
        }
        #expect(store.journal == nil)
        #expect(store.materializedPlan == nil)
        #expect(queue.enqueuedMutations.isEmpty)
        #expect(cleaner.cleanedServerIDs.isEmpty)
    }

    @Test
    func queueFailureIsDurableAndRestartCompletesEveryPhase() throws {
        let fixture = WorkspaceDeletionFixture()
        let store = TestWorkspaceDeletionStore()
        let failingQueue = TestWorkspaceDeletionQueue(shouldFail: true)
        let firstCleaner = TestWorkspaceCredentialCleaner()
        let firstTransaction = ServerDataMutationTransaction(
            store: store,
            mutationQueue: failingQueue,
            credentials: firstCleaner
        )

        let failedJournal = try firstTransaction.commit(
            ServerDataMutationPlan(workspaceDeletion: fixture.plan)
        )

        #expect(failedJournal.lastFailure?.stage == .pendingSyncQueue)
        #expect(store.journal == failedJournal)
        #expect(store.materializedPlan == failedJournal.plan)
        #expect(firstCleaner.cleanedServerIDs == [
            fixture.firstServer.id,
            fixture.secondServer.id
        ])

        let recoveredQueue = TestWorkspaceDeletionQueue()
        let recoveredCleaner = TestWorkspaceCredentialCleaner()
        let restartedTransaction = ServerDataMutationTransaction(
            store: store,
            mutationQueue: recoveredQueue,
            credentials: recoveredCleaner
        )
        let recoveredJournal = try #require(try restartedTransaction.resumePending())

        #expect(recoveredJournal.phase == .complete)
        #expect(recoveredQueue.enqueuedMutations == fixture.plan.pendingMutations)
        #expect(recoveredCleaner.cleanedServerIDs.isEmpty)
        #expect(store.journal == nil)
    }

    @Test
    func localStoreLoadsCommittedPlanAcrossRestart() throws {
        let fixture = WorkspaceDeletionFixture()
        let suiteName = "WorkspaceDeletionTransactionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerLocalStore(defaults: defaults)

        try store.storeServers(fixture.allServers)
        try store.storeWorkspaces(fixture.allWorkspaces)
        var journal = ServerDataMutationJournal(
            plan: ServerDataMutationPlan(workspaceDeletion: fixture.plan)
        )
        journal.didMaterializeLocalState = true
        journal.pendingCredentialServerIDs = []
        journal.didFinalizeCredentials = true
        try store.storeServerDataMutationJournal(journal)

        let restartedStore = ServerLocalStore(defaults: defaults)
        guard case .loaded(let servers) = restartedStore.loadServers(),
              case .loaded(let workspaces) = restartedStore.loadWorkspaces() else {
            Issue.record("Expected the committed deletion plan after restart")
            return
        }

        #expect(servers == fixture.plan.remainingServers)
        #expect(workspaces == fixture.plan.remainingWorkspaces)
    }

    @Test
    func journalClearFailureRemainsInFinalizingPhaseUntilRestart() throws {
        let fixture = WorkspaceDeletionFixture()
        let store = TestWorkspaceDeletionStore()
        store.failJournalClear = true
        let transaction = ServerDataMutationTransaction(
            store: store,
            mutationQueue: TestWorkspaceDeletionQueue(),
            credentials: TestWorkspaceCredentialCleaner()
        )

        let failedJournal = try transaction.commit(
            ServerDataMutationPlan(workspaceDeletion: fixture.plan)
        )

        #expect(failedJournal.phase == .finalizing)
        #expect(failedJournal.lastFailure?.stage == .localPersistence)
        #expect(store.journal == failedJournal)

        store.failJournalClear = false
        let recoveredJournal = try #require(try transaction.resumePending())
        #expect(recoveredJournal.phase == .complete)
        #expect(store.journal == nil)
    }

    @Test
    func deletionPlanRevalidationRejectsChangesDuringAuthorization() throws {
        let fixture = WorkspaceDeletionFixture()
        let unchangedPlan = try #require(WorkspaceDeletionPlan(
            workspaceID: fixture.workspace.id,
            servers: fixture.allServers,
            workspaces: fixture.allWorkspaces,
            id: UUID(),
            mutationIDs: [UUID(), UUID(), UUID()],
            mutationDate: Date(timeIntervalSinceReferenceDate: 2_000)
        ))
        #expect(fixture.plan.hasSameDeletionSnapshot(as: unchangedPlan))

        let newlyProtectedServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
            workspaceId: fixture.workspace.id,
            name: "Added During Authorization",
            host: "added.example.test",
            username: "root",
            requiresBiometricUnlock: true
        )
        let changedPlan = try #require(WorkspaceDeletionPlan(
            workspaceID: fixture.workspace.id,
            servers: fixture.allServers + [newlyProtectedServer],
            workspaces: fixture.allWorkspaces,
            id: UUID(),
            mutationIDs: [UUID(), UUID(), UUID(), UUID()],
            mutationDate: Date(timeIntervalSinceReferenceDate: 2_000)
        ))

        #expect(!fixture.plan.hasSameDeletionSnapshot(as: changedPlan))
    }
}

@MainActor
private final class TestWorkspaceDeletionStore: ServerDataMutationJournalStoring {
    var journal: ServerDataMutationJournal?
    var materializedPlan: ServerDataMutationPlan?
    var failNextJournalWrite = false
    var failJournalClear = false

    func loadServerDataMutationJournal() throws -> ServerDataMutationJournal? {
        journal
    }

    func storeServerDataMutationJournal(_ journal: ServerDataMutationJournal) throws {
        if failNextJournalWrite {
            failNextJournalWrite = false
            throw TestWorkspaceDeletionError.writeFailed
        }
        self.journal = journal
    }

    func materializeServerDataMutation(_ plan: ServerDataMutationPlan) throws {
        materializedPlan = plan
    }

    func clearServerDataMutationJournal() throws {
        guard !failJournalClear else {
            throw TestWorkspaceDeletionError.writeFailed
        }
        journal = nil
    }
}

@MainActor
private final class TestWorkspaceDeletionQueue: ServerDataMutationEnqueuing {
    private let shouldFail: Bool
    private(set) var enqueuedMutations: [ServerPendingMutation] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func enqueueServerDataMutations(_ mutations: [ServerPendingMutation]) throws {
        guard !shouldFail else { throw TestWorkspaceDeletionError.queueFailed }
        enqueuedMutations.append(contentsOf: mutations)
    }
}

@MainActor
private final class TestWorkspaceCredentialCleaner: ServerMutationCredentialTransacting {
    private let failingServerID: UUID?
    private(set) var cleanedServerIDs: [UUID] = []

    init(failingServerID: UUID? = nil) {
        self.failingServerID = failingServerID
    }

    func cleanupCredentials(for server: Server) throws {
        cleanedServerIDs.append(server.id)
        if server.id == failingServerID {
            throw TestWorkspaceDeletionError.credentialCleanupFailed
        }
    }

    func prepareServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server,
        credentials: ServerCredentials
    ) throws {}

    func commitServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server
    ) throws {}

    func discardServerCredentialTransaction(id: UUID) throws {}
}

private enum TestWorkspaceDeletionError: Error {
    case writeFailed
    case queueFailed
    case credentialCleanupFailed
}

private struct WorkspaceDeletionFixture {
    let workspace: Workspace
    let otherWorkspace: Workspace
    let firstServer: Server
    let secondServer: Server
    let otherServer: Server
    let plan: WorkspaceDeletionPlan

    init() {
        let workspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Delete",
            order: 0
        )
        let otherWorkspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Keep",
            order: 1
        )
        let firstServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspace.id,
            name: "First",
            host: "first.example.test",
            username: "root"
        )
        let secondServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceId: workspace.id,
            name: "Second",
            host: "second.example.test",
            username: "root"
        )
        let otherServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            workspaceId: otherWorkspace.id,
            name: "Keep",
            host: "keep.example.test",
            username: "root"
        )
        self.workspace = workspace
        self.otherWorkspace = otherWorkspace
        self.firstServer = firstServer
        self.secondServer = secondServer
        self.otherServer = otherServer
        self.plan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: [firstServer, secondServer, otherServer],
            workspaces: [workspace, otherWorkspace],
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            mutationIDs: [
                UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
                UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
            ],
            mutationDate: Date(timeIntervalSinceReferenceDate: 1_000)
        )!
    }

    var allServers: [Server] { [firstServer, secondServer, otherServer] }
    var allWorkspaces: [Workspace] { [workspace, otherWorkspace] }
}
