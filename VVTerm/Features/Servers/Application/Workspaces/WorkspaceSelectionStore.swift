import Combine
import Foundation

nonisolated enum StoredWorkspaceEnvironmentFilters: Equatable, Sendable {
    case absent
    case current(WorkspaceEnvironmentFilters)
    case requiresNormalization(WorkspaceEnvironmentFilters)

    var filters: WorkspaceEnvironmentFilters {
        switch self {
        case .absent:
            .empty
        case .current(let filters), .requiresNormalization(let filters):
            filters
        }
    }

    var hasStoredValue: Bool {
        switch self {
        case .absent:
            false
        case .current, .requiresNormalization:
            true
        }
    }

    var requiresNormalization: Bool {
        if case .requiresNormalization = self {
            return true
        }
        return false
    }
}

nonisolated struct LegacyWorkspaceEnvironmentFilters: Equatable, Sendable {
    let selectedIDs: Set<UUID>
    let hasStoredValue: Bool
}

@MainActor
protocol WorkspaceSelectionPersisting: AnyObject {
    func loadEnvironmentFilters() -> StoredWorkspaceEnvironmentFilters
    @discardableResult
    func saveEnvironmentFilters(_ filters: WorkspaceEnvironmentFilters) -> Bool
    func loadLegacyEnvironmentFilters() -> LegacyWorkspaceEnvironmentFilters
    func clearLegacyEnvironmentFilters()
}

@MainActor
final class WorkspaceSelectionStore: ObservableObject {
    @Published private var storedFilters: StoredWorkspaceEnvironmentFilters

    private let persistence: any WorkspaceSelectionPersisting

    init(persistence: any WorkspaceSelectionPersisting) {
        self.persistence = persistence
        storedFilters = persistence.loadEnvironmentFilters()
    }

    func environmentFilterIDs(for workspace: Workspace?) -> Set<UUID> {
        WorkspaceSelectionPolicy.environmentFilterIDs(
            in: storedFilters.filters,
            workspace: workspace
        )
    }

    func updateEnvironmentFilterIDs(
        _ selected: Set<UUID>,
        for workspace: Workspace?
    ) {
        let updated = WorkspaceSelectionPolicy.updatingEnvironmentFilterIDs(
            selected,
            for: workspace,
            in: storedFilters.filters
        )
        persist(updated)
    }

    func reconcile(
        workspaces: [Workspace],
        legacyMigrationWorkspace: Workspace?
    ) {
        let legacy = persistence.loadLegacyEnvironmentFilters()
        var filters = storedFilters.filters

        if !storedFilters.hasStoredValue, legacy.hasStoredValue {
            filters = WorkspaceSelectionPolicy.updatingEnvironmentFilterIDs(
                legacy.selectedIDs,
                for: legacyMigrationWorkspace,
                in: filters
            )
        }

        filters = WorkspaceSelectionPolicy.reconciledEnvironmentFilters(
            filters,
            workspaces: workspaces
        )

        if storedFilters.requiresNormalization || filters != storedFilters.filters {
            persist(filters)
        }
        if legacy.hasStoredValue {
            persistence.clearLegacyEnvironmentFilters()
        }
    }

    private func persist(_ filters: WorkspaceEnvironmentFilters) {
        guard filters != storedFilters.filters || storedFilters.requiresNormalization else {
            return
        }
        guard persistence.saveEnvironmentFilters(filters) else { return }
        storedFilters = filters == .empty ? .absent : .current(filters)
    }
}
