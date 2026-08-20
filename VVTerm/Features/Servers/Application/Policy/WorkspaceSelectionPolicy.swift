import Foundation

nonisolated struct WorkspaceEnvironmentFilters: Equatable, Sendable {
    static let empty = Self()

    let selectionsByWorkspace: [UUID: Set<UUID>]

    init(selectionsByWorkspace: [UUID: Set<UUID>] = [:]) {
        self.selectionsByWorkspace = selectionsByWorkspace
    }
}

enum WorkspaceSelectionPolicy {
    static func workspace(
        current: Workspace?,
        available: [Workspace]
    ) -> Workspace? {
        guard let current else { return available.first }
        return available.first { $0.id == current.id } ?? available.first
    }

    static func environment(
        current: ServerEnvironment?,
        workspace: Workspace?
    ) -> ServerEnvironment? {
        guard let current, let workspace else { return nil }
        return workspace.environment(withId: current.id)
    }

    static func environment(
        current: ServerEnvironment?,
        afterDeleting environmentID: UUID,
        result: EnvironmentDeletionResult
    ) -> ServerEnvironment? {
        guard let current else { return nil }
        if current.id == environmentID {
            return result.selectedEnvironment
        }
        return result.workspace.environment(withId: current.id)
    }

    static func server(current: Server?, available: [Server]) -> Server? {
        guard let current else { return nil }
        return available.first { $0.id == current.id }
    }

    static func environmentFilterIDs(
        in filters: WorkspaceEnvironmentFilters,
        workspace: Workspace?
    ) -> Set<UUID> {
        guard let workspace else { return [] }
        let selected = filters.selectionsByWorkspace[workspace.id] ?? []
        return selected.intersection(workspace.environments.map(\.id))
    }

    static func updatingEnvironmentFilterIDs(
        _ selected: Set<UUID>,
        for workspace: Workspace?,
        in filters: WorkspaceEnvironmentFilters
    ) -> WorkspaceEnvironmentFilters {
        guard let workspace else { return filters }

        var selections = filters.selectionsByWorkspace
        let available = Set(workspace.environments.map(\.id))
        let normalized = selected.intersection(available)

        if normalized.isEmpty || normalized == available {
            selections.removeValue(forKey: workspace.id)
        } else {
            selections[workspace.id] = normalized
        }

        return WorkspaceEnvironmentFilters(selectionsByWorkspace: selections)
    }

    static func reconciledEnvironmentFilters(
        _ filters: WorkspaceEnvironmentFilters,
        workspaces: [Workspace]
    ) -> WorkspaceEnvironmentFilters {
        let availableByWorkspace = workspaces.reduce(into: [UUID: Set<UUID>]()) { result, workspace in
            result[workspace.id] = Set(workspace.environments.map(\.id))
        }
        let reconciled = filters.selectionsByWorkspace.reduce(into: [UUID: Set<UUID>]()) { result, item in
            guard let available = availableByWorkspace[item.key] else { return }
            let normalized = item.value.intersection(available)
            guard !normalized.isEmpty, normalized != available else { return }
            result[item.key] = normalized
        }
        return WorkspaceEnvironmentFilters(selectionsByWorkspace: reconciled)
    }
}

nonisolated enum ServerCreationPresentationStep: Equatable, Sendable {
    case createWorkspace
    case createServer
}

nonisolated enum ServerCreationPresentationPolicy {
    static func initialStep(canAddServer: Bool) -> ServerCreationPresentationStep {
        canAddServer ? .createServer : .createWorkspace
    }

    static func shouldResumePrefilledServer(
        hasPrefill: Bool,
        canAddServer: Bool,
        isPresentingServer: Bool
    ) -> Bool {
        hasPrefill && canAddServer && !isPresentingServer
    }
}
