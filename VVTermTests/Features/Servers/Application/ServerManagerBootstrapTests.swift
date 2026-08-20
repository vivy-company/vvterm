import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct ServerManagerBootstrapTests {
    @Test
    func bootstrapCreationRunsOnlyBeforeAnyFirstRunMarkerExists() {
        #expect(
            ServerStateStore.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: false,
                hasLocalWorkspaces: false
            )
        )
    }

    @Test
    func bootstrapCreationIsBlockedByEitherBootstrapFlagOrWelcomeFlag() {
        #expect(
            !ServerStateStore.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: true,
                hasSeenWelcome: false,
                hasLocalWorkspaces: false
            )
        )
        #expect(
            !ServerStateStore.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: true,
                hasLocalWorkspaces: false
            )
        )
        #expect(
            !ServerStateStore.shouldCreateBootstrapWorkspace(
                didBootstrapDefaultWorkspace: false,
                hasSeenWelcome: false,
                hasLocalWorkspaces: true
            )
        )
    }

    @Test
    func backfillCandidatesUseOnlyExplicitPendingUpserts() {
        let remoteWorkspace = Workspace(id: UUID(), name: "Remote", order: 1)
        let remoteServer = Server(
            id: UUID(),
            workspaceId: remoteWorkspace.id,
            name: "Needs Upload",
            host: "remote.example.com",
            username: "root"
        )

        let candidates = ServerStateStore.backfillCandidates(
            pendingMutations: [
                ServerPendingMutation(
                    id: UUID(),
                    payload: .serverUpsert(remoteServer),
                    createdAt: .distantPast
                )
            ],
            cloudWorkspaceIDs: [remoteWorkspace.id],
            cloudServerIDs: [],
            deletedWorkspaceIDs: [],
            deletedServerIDs: []
        )

        #expect(candidates.workspaces.isEmpty)
        #expect(candidates.servers.map(\.id) == [remoteServer.id])
    }

    @Test
    func canonicalDefaultWorkspaceDetectionAcceptsLocalizedNames() {
        let localizedWorkspace = Workspace(
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.zhHans.rawValue),
            order: 0
        )

        #expect(
            ServerStateStore.isCanonicalDefaultWorkspaceCandidate(
                localizedWorkspace,
                canonicalNames: Set(AppLanguage.localizedValues(for: "My Servers"))
            )
        )
    }

    @Test
    func backfillCandidatesIncludeBootstrapWorkspaceAfterPromotion() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: AppLanguage.localizedString("My Servers", rawValue: AppLanguage.en.rawValue),
            order: 0
        )

        let candidates = ServerStateStore.backfillCandidates(
            pendingMutations: [
                ServerPendingMutation(
                    id: UUID(),
                    payload: .workspaceUpsert(bootstrapWorkspace),
                    createdAt: .distantPast
                )
            ],
            cloudWorkspaceIDs: [],
            cloudServerIDs: [],
            deletedWorkspaceIDs: [],
            deletedServerIDs: []
        )

        #expect(candidates.workspaces.map(\.id) == [bootstrapWorkspace.id])
        #expect(candidates.servers.isEmpty)
    }

    @Test
    func remoteDeletionExcludesPendingBackfillCandidate() {
        let workspace = Workspace(id: UUID(), name: "Workspace", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Deleted Elsewhere",
            host: "deleted.example.com",
            username: "root"
        )
        let candidates = ServerStateStore.backfillCandidates(
            pendingMutations: [
                ServerPendingMutation(
                    id: UUID(),
                    payload: .workspaceUpsert(workspace),
                    createdAt: .distantPast
                ),
                ServerPendingMutation(
                    id: UUID(),
                    payload: .serverUpsert(server),
                    createdAt: .distantPast
                )
            ],
            cloudWorkspaceIDs: [],
            cloudServerIDs: [],
            deletedWorkspaceIDs: [],
            deletedServerIDs: [server.id]
        )

        #expect(candidates.workspaces.map(\.id) == [workspace.id])
        #expect(candidates.servers.isEmpty)
    }

    @Test
    func orphanRepairCreatesFallbackWorkspaceWhenServersExistWithoutAnyWorkspace() {
        let orphanedServer = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "Lost Server",
            host: "lost.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "My Servers", order: 0)

        let repairWorkspace = ServerStateStore.workspaceForOrphanRepair(
            existingWorkspaces: [],
            servers: [orphanedServer],
            fallbackWorkspace: fallbackWorkspace
        )

        #expect(repairWorkspace?.id == fallbackWorkspace.id)
    }

    @Test
    func orphanRepairDoesNothingWhenAllServersAlreadyHaveValidWorkspaces() {
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let validServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Healthy",
            host: "healthy.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "Fallback", order: 1)

        let repairWorkspace = ServerStateStore.workspaceForOrphanRepair(
            existingWorkspaces: [workspace],
            servers: [validServer],
            fallbackWorkspace: fallbackWorkspace
        )

        #expect(repairWorkspace == nil)
    }
}
