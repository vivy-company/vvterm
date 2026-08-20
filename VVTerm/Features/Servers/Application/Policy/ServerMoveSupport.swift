import Foundation

nonisolated enum ServerMoveSupport {
    static func allowedDestinationIDs(
        isPro: Bool,
        sourceWorkspaceId: UUID,
        workspacesInOrder: [Workspace],
        unlockedWorkspaceIds: Set<UUID>
    ) -> Set<UUID> {
        let orderedIDs = workspacesInOrder.map(\.id)

        if isPro {
            return Set(orderedIDs.filter { $0 != sourceWorkspaceId })
        }

        let sourceIsUnlocked = unlockedWorkspaceIds.contains(sourceWorkspaceId)
        if sourceIsUnlocked {
            return Set(orderedIDs.filter { $0 != sourceWorkspaceId && unlockedWorkspaceIds.contains($0) })
        }

        return unlockedWorkspaceIds
    }

    static func resolveEnvironment(
        currentEnvironment: ServerEnvironment,
        preferredEnvironment: ServerEnvironment? = nil,
        destination: Workspace
    ) -> ServerEnvironment {
        if let preferredEnvironment,
           let matchedPreferred = destination.environment(withId: preferredEnvironment.id) {
            return matchedPreferred
        }

        if let matchedCurrent = destination.environment(withId: currentEnvironment.id) {
            return matchedCurrent
        }

        if let production = destination.environment(withId: ServerEnvironment.production.id) {
            return production
        }

        return destination.environments.first ?? .production
    }

    static func requiresEnvironmentFallback(
        currentEnvironment: ServerEnvironment,
        destination: Workspace
    ) -> Bool {
        destination.environment(withId: currentEnvironment.id) == nil
    }
}
