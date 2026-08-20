import Foundation

nonisolated struct ServerDataMutationPlan: Codable, Equatable, Identifiable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case serverSave(UUID)
        case serverDelete(UUID)
        case workspaceUpsert(UUID)
        case workspaceBatchUpsert([UUID])
        case workspaceDelete(UUID)
        case environmentDelete(workspaceID: UUID, environmentID: UUID)
    }

    enum CredentialAction: Codable, Equatable, Sendable {
        case none
        case replace(
            transactionID: UUID,
            previousServer: Server?,
            server: Server
        )
        case delete([Server])
    }

    let id: UUID
    let kind: Kind
    let previousServers: [Server]
    let previousWorkspaces: [Workspace]
    let resultingServers: [Server]
    let resultingWorkspaces: [Workspace]
    let pendingMutations: [ServerPendingMutation]
    let credentialAction: CredentialAction

    init(
        id: UUID,
        kind: Kind,
        previousServers: [Server],
        previousWorkspaces: [Workspace],
        resultingServers: [Server],
        resultingWorkspaces: [Workspace],
        pendingMutations: [ServerPendingMutation],
        credentialAction: CredentialAction = .none
    ) {
        self.id = id
        self.kind = kind
        self.previousServers = previousServers
        self.previousWorkspaces = previousWorkspaces
        self.resultingServers = resultingServers
        self.resultingWorkspaces = resultingWorkspaces
        self.pendingMutations = pendingMutations
        self.credentialAction = credentialAction
    }

    init(
        id: UUID,
        previousServers: [Server],
        previousWorkspaces: [Workspace],
        resultingServers: [Server],
        resultingWorkspaces: [Workspace],
        pendingMutation: ServerPendingMutation,
        credentialAction: CredentialAction
    ) {
        let kind: Kind
        switch credentialAction {
        case .replace(_, _, let server):
            kind = .serverSave(server.id)
        case .delete(let servers):
            guard servers.count == 1, let server = servers.first else {
                preconditionFailure("A single server deletion requires one credential bundle")
            }
            kind = .serverDelete(server.id)
        case .none:
            preconditionFailure("A server mutation requires a credential action")
        }
        self.init(
            id: id,
            kind: kind,
            previousServers: previousServers,
            previousWorkspaces: previousWorkspaces,
            resultingServers: resultingServers,
            resultingWorkspaces: resultingWorkspaces,
            pendingMutations: [pendingMutation],
            credentialAction: credentialAction
        )
    }

    init(workspaceDeletion plan: WorkspaceDeletionPlan) {
        self.init(
            id: plan.id,
            kind: .workspaceDelete(plan.workspace.id),
            previousServers: plan.previousServers,
            previousWorkspaces: plan.previousWorkspaces,
            resultingServers: plan.remainingServers,
            resultingWorkspaces: plan.remainingWorkspaces,
            pendingMutations: plan.pendingMutations,
            credentialAction: .delete(plan.deletedServers)
        )
    }

    init(
        environmentDeletion plan: EnvironmentDeletionPlan,
        previousServers: [Server],
        previousWorkspaces: [Workspace]
    ) {
        self.init(
            id: plan.id,
            kind: .environmentDelete(
                workspaceID: plan.workspaceID,
                environmentID: plan.environmentID
            ),
            previousServers: previousServers,
            previousWorkspaces: previousWorkspaces,
            resultingServers: plan.resultingServers,
            resultingWorkspaces: plan.resultingWorkspaces,
            pendingMutations: plan.pendingMutations
        )
    }

    var deletedServers: [Server] {
        guard case .delete(let servers) = credentialAction else { return [] }
        return servers
    }
}

nonisolated struct ServerDataMutationJournal: Codable, Equatable, Sendable {
    enum FailureStage: String, Codable, Equatable, Sendable {
        case credentialPreparation
        case localPersistence
        case credentialFinalization
        case pendingSyncQueue
        case credentialStagingCleanup
    }

    struct Failure: Codable, Equatable, Sendable {
        let stage: FailureStage
        let message: String
    }

    enum Phase: Equatable, Sendable {
        case preparingCredentials
        case materializing
        case finalizingCredentials
        case enqueueing
        case cleaningCredentialStaging
        case finalizing
        case complete
    }

    let plan: ServerDataMutationPlan
    var didPrepareCredentials: Bool
    var didMaterializeLocalState = false
    var pendingCredentialServerIDs: [UUID]
    var didFinalizeCredentials: Bool
    var didEnqueuePendingMutations = false
    var didCleanCredentialStaging: Bool
    var didFinalize = false
    var lastFailure: Failure?

    init(plan: ServerDataMutationPlan) {
        self.plan = plan
        switch plan.credentialAction {
        case .none:
            didPrepareCredentials = true
            pendingCredentialServerIDs = []
            didFinalizeCredentials = true
            didCleanCredentialStaging = true
        case .replace:
            didPrepareCredentials = false
            pendingCredentialServerIDs = []
            didFinalizeCredentials = false
            didCleanCredentialStaging = false
        case .delete(let servers):
            didPrepareCredentials = true
            pendingCredentialServerIDs = servers.map(\.id)
            didFinalizeCredentials = servers.isEmpty
            didCleanCredentialStaging = true
        }
    }

    var phase: Phase {
        if !didPrepareCredentials { return .preparingCredentials }
        if !didMaterializeLocalState { return .materializing }
        if !didFinalizeCredentials { return .finalizingCredentials }
        if !didEnqueuePendingMutations { return .enqueueing }
        if !didCleanCredentialStaging { return .cleaningCredentialStaging }
        return didFinalize ? .complete : .finalizing
    }

    var presentsResultingState: Bool {
        didMaterializeLocalState && didFinalizeCredentials
    }
}

@MainActor
protocol ServerDataMutationJournalStoring {
    func loadServerDataMutationJournal() throws -> ServerDataMutationJournal?
    func storeServerDataMutationJournal(_ journal: ServerDataMutationJournal) throws
    func materializeServerDataMutation(_ plan: ServerDataMutationPlan) throws
    func clearServerDataMutationJournal() throws
}

@MainActor
protocol ServerDataMutationEnqueuing {
    func enqueueServerDataMutations(_ mutations: [ServerPendingMutation]) throws
}

@MainActor
protocol ServerMutationCredentialTransacting {
    func prepareServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server,
        credentials: ServerCredentials
    ) throws
    func commitServerCredentialTransaction(
        id: UUID,
        previousServer: Server?,
        server: Server
    ) throws
    func discardServerCredentialTransaction(id: UUID) throws
    func cleanupCredentials(for server: Server) throws
}

@MainActor
struct ServerDataMutationTransaction {
    private let store: any ServerDataMutationJournalStoring
    private let mutationQueue: any ServerDataMutationEnqueuing
    private let credentials: any ServerMutationCredentialTransacting

    init(
        store: any ServerDataMutationJournalStoring,
        mutationQueue: any ServerDataMutationEnqueuing,
        credentials: any ServerMutationCredentialTransacting
    ) {
        self.store = store
        self.mutationQueue = mutationQueue
        self.credentials = credentials
    }

    func commitSave(
        _ plan: ServerDataMutationPlan,
        credentials newCredentials: ServerCredentials
    ) throws -> ServerDataMutationJournal {
        guard try store.loadServerDataMutationJournal() == nil else {
            throw ServerDataMutationTransactionError.recoveryPending
        }
        guard case .replace(let transactionID, let previousServer, let server) = plan.credentialAction else {
            preconditionFailure("A server save transaction requires replacement credentials")
        }

        var journal = ServerDataMutationJournal(plan: plan)
        try store.storeServerDataMutationJournal(journal)

        do {
            try credentials.prepareServerCredentialTransaction(
                id: transactionID,
                previousServer: previousServer,
                server: server,
                credentials: newCredentials
            )
            journal.didPrepareCredentials = true
            journal.lastFailure = nil
            try store.storeServerDataMutationJournal(journal)
        } catch {
            try? credentials.discardServerCredentialTransaction(id: transactionID)
            try? store.clearServerDataMutationJournal()
            throw error
        }

        return resume(journal)
    }

    func commit(_ plan: ServerDataMutationPlan) throws -> ServerDataMutationJournal {
        guard try store.loadServerDataMutationJournal() == nil else {
            throw ServerDataMutationTransactionError.recoveryPending
        }
        guard case .replace = plan.credentialAction else {
            let journal = ServerDataMutationJournal(plan: plan)
            try store.storeServerDataMutationJournal(journal)
            return resume(journal)
        }
        preconditionFailure("Use commitSave for a credential replacement")
    }

    func resumePending() throws -> ServerDataMutationJournal? {
        guard let journal = try store.loadServerDataMutationJournal() else { return nil }
        if !journal.didPrepareCredentials {
            if case .replace(let transactionID, _, _) = journal.plan.credentialAction {
                try credentials.discardServerCredentialTransaction(id: transactionID)
            }
            try store.clearServerDataMutationJournal()
            return nil
        }
        return resume(journal)
    }

    private func resume(_ storedJournal: ServerDataMutationJournal) -> ServerDataMutationJournal {
        var journal = storedJournal

        if !journal.didMaterializeLocalState {
            do {
                try store.materializeServerDataMutation(journal.plan)
                journal.didMaterializeLocalState = true
                journal.lastFailure = nil
                try store.storeServerDataMutationJournal(journal)
            } catch {
                return recording(error, at: .localPersistence, in: journal)
            }
        }

        if !journal.didFinalizeCredentials {
            do {
                switch journal.plan.credentialAction {
                case .none:
                    break
                case .replace(let transactionID, let previousServer, let server):
                    try credentials.commitServerCredentialTransaction(
                        id: transactionID,
                        previousServer: previousServer,
                        server: server
                    )
                case .delete(let servers):
                    while let serverID = journal.pendingCredentialServerIDs.first,
                          let server = servers.first(where: { $0.id == serverID }) {
                        try credentials.cleanupCredentials(for: server)
                        journal.pendingCredentialServerIDs.removeFirst()
                        try store.storeServerDataMutationJournal(journal)
                    }
                }
                journal.didFinalizeCredentials = true
                journal.lastFailure = nil
                try store.storeServerDataMutationJournal(journal)
            } catch {
                return recording(error, at: .credentialFinalization, in: journal)
            }
        }

        do {
            try store.materializeServerDataMutation(journal.plan)
        } catch {
            return recording(error, at: .localPersistence, in: journal)
        }

        if !journal.didEnqueuePendingMutations {
            do {
                try mutationQueue.enqueueServerDataMutations(journal.plan.pendingMutations)
                journal.didEnqueuePendingMutations = true
                journal.lastFailure = nil
                try store.storeServerDataMutationJournal(journal)
            } catch {
                return recording(error, at: .pendingSyncQueue, in: journal)
            }
        }

        if !journal.didCleanCredentialStaging,
           case .replace(let transactionID, _, _) = journal.plan.credentialAction {
            do {
                try credentials.discardServerCredentialTransaction(id: transactionID)
                journal.didCleanCredentialStaging = true
                journal.lastFailure = nil
                try store.storeServerDataMutationJournal(journal)
            } catch {
                return recording(error, at: .credentialStagingCleanup, in: journal)
            }
        }

        if !journal.didFinalize {
            do {
                try store.clearServerDataMutationJournal()
                journal.didFinalize = true
                journal.lastFailure = nil
            } catch {
                return recording(error, at: .localPersistence, in: journal)
            }
        }
        return journal
    }

    private func recording(
        _ error: Error,
        at stage: ServerDataMutationJournal.FailureStage,
        in journal: ServerDataMutationJournal
    ) -> ServerDataMutationJournal {
        var failed = journal
        failed.lastFailure = ServerDataMutationJournal.Failure(
            stage: stage,
            message: error.localizedDescription
        )
        try? store.storeServerDataMutationJournal(failed)
        return failed
    }
}

nonisolated enum ServerDataMutationTransactionError: LocalizedError, Equatable, Sendable {
    case recoveryPending

    var errorDescription: String? {
        String(localized: "A server data change is still recovering. Try again after recovery completes.")
    }
}
