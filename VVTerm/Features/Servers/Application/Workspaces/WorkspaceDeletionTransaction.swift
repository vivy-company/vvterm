import Foundation

nonisolated struct WorkspaceDeletionPlan: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspace: Workspace
    let deletedServers: [Server]
    let previousServers: [Server]
    let previousWorkspaces: [Workspace]
    let remainingServers: [Server]
    let remainingWorkspaces: [Workspace]
    let pendingMutations: [ServerPendingMutation]

    init?(
        workspaceID: UUID,
        servers: [Server],
        workspaces: [Workspace],
        id: UUID,
        mutationIDs: [UUID],
        mutationDate: Date
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }

        let deletedServers = servers.filter { $0.workspaceId == workspaceID }
        guard let workspaceMutationID = mutationIDs.last,
              mutationIDs.dropLast().count == deletedServers.count else {
            return nil
        }
        self.id = id
        self.workspace = workspace
        self.deletedServers = deletedServers
        self.previousServers = servers
        self.previousWorkspaces = workspaces
        self.remainingServers = servers.filter { $0.workspaceId != workspaceID }
        self.remainingWorkspaces = workspaces.filter { $0.id != workspaceID }
        self.pendingMutations = deletedServers.enumerated().map { index, server in
            ServerPendingMutation(
                id: mutationIDs[index],
                payload: .serverDelete(server),
                createdAt: mutationDate.addingTimeInterval(TimeInterval(index))
            )
        } + [
            ServerPendingMutation(
                id: workspaceMutationID,
                payload: .workspaceDelete(workspace),
                createdAt: mutationDate.addingTimeInterval(TimeInterval(deletedServers.count))
            )
        ]
    }

    func hasSameDeletionSnapshot(as other: WorkspaceDeletionPlan) -> Bool {
        workspace == other.workspace &&
        deletedServers == other.deletedServers &&
        remainingServers == other.remainingServers &&
        remainingWorkspaces == other.remainingWorkspaces
    }
}
