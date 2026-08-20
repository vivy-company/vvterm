import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class RecordingWorkspaceSelectionPersistence: WorkspaceSelectionPersisting {
    var stored: StoredWorkspaceEnvironmentFilters
    var legacy: LegacyWorkspaceEnvironmentFilters
    var allowsSave = true
    private(set) var saved: [WorkspaceEnvironmentFilters] = []
    private(set) var legacyClearCount = 0

    init(
        stored: StoredWorkspaceEnvironmentFilters,
        legacy: LegacyWorkspaceEnvironmentFilters = LegacyWorkspaceEnvironmentFilters(
            selectedIDs: [],
            hasStoredValue: false
        )
    ) {
        self.stored = stored
        self.legacy = legacy
    }

    func loadEnvironmentFilters() -> StoredWorkspaceEnvironmentFilters {
        stored
    }

    func saveEnvironmentFilters(_ filters: WorkspaceEnvironmentFilters) -> Bool {
        guard allowsSave else { return false }
        saved.append(filters)
        stored = filters == .empty ? .absent : .current(filters)
        return true
    }

    func loadLegacyEnvironmentFilters() -> LegacyWorkspaceEnvironmentFilters {
        legacy
    }

    func clearLegacyEnvironmentFilters() {
        legacyClearCount += 1
        legacy = LegacyWorkspaceEnvironmentFilters(
            selectedIDs: [],
            hasStoredValue: false
        )
    }
}

@MainActor
struct WorkspaceSelectionStoreTests {
    @Test
    func migratesLegacySelectionOnlyWhenCurrentStateIsAbsent() {
        let first = Workspace(
            name: "First",
            environments: [.production, .staging]
        )
        let second = Workspace(
            name: "Second",
            environments: [.production, .staging]
        )
        let persistence = RecordingWorkspaceSelectionPersistence(
            stored: .absent,
            legacy: LegacyWorkspaceEnvironmentFilters(
                selectedIDs: [ServerEnvironment.staging.id],
                hasStoredValue: true
            )
        )
        let store = WorkspaceSelectionStore(persistence: persistence)

        store.reconcile(
            workspaces: [first, second],
            legacyMigrationWorkspace: first
        )

        #expect(store.environmentFilterIDs(for: first) == [ServerEnvironment.staging.id])
        #expect(store.environmentFilterIDs(for: second).isEmpty)
        #expect(persistence.saved.count == 1)
        #expect(persistence.legacyClearCount == 1)
    }

    @Test
    func existingCurrentStateBlocksLegacyMigration() {
        let workspace = Workspace(
            name: "Workspace",
            environments: [.production, .staging]
        )
        let current = WorkspaceEnvironmentFilters(
            selectionsByWorkspace: [workspace.id: [ServerEnvironment.production.id]]
        )
        let persistence = RecordingWorkspaceSelectionPersistence(
            stored: .current(current),
            legacy: LegacyWorkspaceEnvironmentFilters(
                selectedIDs: [ServerEnvironment.staging.id],
                hasStoredValue: true
            )
        )
        let store = WorkspaceSelectionStore(persistence: persistence)

        store.reconcile(
            workspaces: [workspace],
            legacyMigrationWorkspace: workspace
        )

        #expect(store.environmentFilterIDs(for: workspace) == [ServerEnvironment.production.id])
        #expect(persistence.saved.isEmpty)
        #expect(persistence.legacyClearCount == 1)
    }

    @Test
    func normalizesInvalidStoredStateAndRejectsFailedWrites() {
        let workspace = Workspace(
            name: "Workspace",
            environments: [.production, .staging]
        )
        let persistence = RecordingWorkspaceSelectionPersistence(
            stored: .requiresNormalization(.empty)
        )
        let store = WorkspaceSelectionStore(persistence: persistence)

        store.reconcile(
            workspaces: [workspace],
            legacyMigrationWorkspace: workspace
        )
        #expect(persistence.saved == [.empty])

        persistence.allowsSave = false
        store.updateEnvironmentFilterIDs([ServerEnvironment.production.id], for: workspace)

        #expect(store.environmentFilterIDs(for: workspace).isEmpty)
        #expect(persistence.saved == [.empty])
    }
}
