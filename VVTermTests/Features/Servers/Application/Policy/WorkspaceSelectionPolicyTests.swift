import Foundation
import Testing
@testable import VVTerm

@MainActor
struct WorkspaceSelectionPolicyTests {
    @Test
    func replacesDeletedWorkspaceAndRefreshesExistingWorkspaceValue() throws {
        let firstID = UUID()
        let original = Workspace(id: firstID, name: "Original")
        let refreshed = Workspace(id: firstID, name: "Refreshed")
        let fallback = Workspace(name: "Fallback")

        let matching = try #require(WorkspaceSelectionPolicy.workspace(
            current: original,
            available: [refreshed, fallback]
        ))
        #expect(matching.name == "Refreshed")

        let replacement = try #require(WorkspaceSelectionPolicy.workspace(
            current: Workspace(name: "Deleted"),
            available: [fallback]
        ))
        #expect(replacement.id == fallback.id)
        #expect(WorkspaceSelectionPolicy.workspace(current: original, available: []) == nil)
    }

    @Test
    func removesEnvironmentSelectionThatIsNotInTheWorkspace() {
        let custom = ServerEnvironment(
            name: "Custom",
            shortName: "C",
            colorHex: "#000000"
        )
        let workspace = Workspace(name: "Workspace", environments: [ServerEnvironment.production])

        #expect(WorkspaceSelectionPolicy.environment(
            current: ServerEnvironment.production,
            workspace: workspace
        ) == ServerEnvironment.production)
        #expect(WorkspaceSelectionPolicy.environment(
            current: custom,
            workspace: workspace
        ) == nil)
    }

    @Test
    func environmentDeletionSelectsFallbackOnlyWhenDeletedEnvironmentWasSelected() {
        let custom = ServerEnvironment(name: "Custom", shortName: "C", colorHex: "#000000")
        let workspace = Workspace(
            name: "Workspace",
            environments: [.production, .staging]
        )
        let result = EnvironmentDeletionResult(
            workspace: workspace,
            selectedEnvironment: .production
        )

        #expect(WorkspaceSelectionPolicy.environment(
            current: custom,
            afterDeleting: custom.id,
            result: result
        ) == .production)
        #expect(WorkspaceSelectionPolicy.environment(
            current: .staging,
            afterDeleting: custom.id,
            result: result
        ) == .staging)
    }

    @Test
    func pendingPrefilledServerResumesOnlyAfterWorkspaceExists() {
        #expect(ServerCreationPresentationPolicy.initialStep(canAddServer: false) == .createWorkspace)
        #expect(ServerCreationPresentationPolicy.initialStep(canAddServer: true) == .createServer)
        #expect(ServerCreationPresentationPolicy.shouldResumePrefilledServer(
            hasPrefill: true,
            canAddServer: true,
            isPresentingServer: false
        ))
        #expect(!ServerCreationPresentationPolicy.shouldResumePrefilledServer(
            hasPrefill: true,
            canAddServer: false,
            isPresentingServer: false
        ))
    }

    @Test
    func storesAndReconcilesFilterIDsByWorkspace() {
        let foreignID = UUID()
        let first = Workspace(
            name: "Workspace",
            environments: [ServerEnvironment.production, ServerEnvironment.staging]
        )
        let secondEnvironment = ServerEnvironment(name: "Second", shortName: "S", colorHex: "#000000")
        let second = Workspace(name: "Second", environments: [secondEnvironment])

        var filters = WorkspaceSelectionPolicy.updatingEnvironmentFilterIDs(
            [ServerEnvironment.production.id, foreignID],
            for: first,
            in: .empty
        )
        filters = WorkspaceSelectionPolicy.updatingEnvironmentFilterIDs(
            [secondEnvironment.id],
            for: second,
            in: filters
        )

        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(in: filters, workspace: first) == [
            ServerEnvironment.production.id
        ])
        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(in: filters, workspace: second).isEmpty)

        let firstWithoutProduction = Workspace(
            id: first.id,
            name: first.name,
            environments: [ServerEnvironment.staging]
        )
        let reconciled = WorkspaceSelectionPolicy.reconciledEnvironmentFilters(
            filters,
            workspaces: [firstWithoutProduction, second]
        )

        #expect(WorkspaceSelectionPolicy.environmentFilterIDs(
            in: reconciled,
            workspace: firstWithoutProduction
        ).isEmpty)
    }
}
