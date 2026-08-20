import Foundation

nonisolated struct ServerRemoteChangeCheckpoint: Equatable, Sendable {
    let id: UUID
}

nonisolated struct ServerRemoteChanges: Equatable, Sendable {
    let servers: [Server]
    let workspaces: [Workspace]
    let deletedServerIDs: [UUID]
    let deletedWorkspaceIDs: [UUID]
    let isFullFetch: Bool
    let checkpoint: ServerRemoteChangeCheckpoint

    init(
        servers: [Server],
        workspaces: [Workspace],
        deletedServerIDs: [UUID],
        deletedWorkspaceIDs: [UUID],
        isFullFetch: Bool,
        checkpoint: ServerRemoteChangeCheckpoint
    ) {
        self.servers = servers
        self.workspaces = workspaces
        self.deletedServerIDs = deletedServerIDs
        self.deletedWorkspaceIDs = deletedWorkspaceIDs
        self.isFullFetch = isFullFetch
        self.checkpoint = checkpoint
    }
}

nonisolated enum AmbiguousCloudRecoveryChoice: Equatable, Sendable {
    case keepLocal
    case uploadLocal
    case replaceWithCloud
}

nonisolated struct AmbiguousCloudRecoveryBackup: Codable, Equatable, Sendable {
    let servers: [Server]
    let workspaces: [Workspace]
}

nonisolated enum AmbiguousCloudRecoveryState: Equatable, Sendable {
    case decisionRequired
}

nonisolated enum AmbiguousCloudRecoveryError: LocalizedError, Equatable, Sendable {
    case fullFetchNeedsDecision
    case remoteUnavailable
    case incompleteSnapshot

    var errorDescription: String? {
        switch self {
        case .fullFetchNeedsDecision:
            return String(
                localized: "Cloud data is missing local items. Choose how VVTerm should recover."
            )
        case .remoteUnavailable:
            return String(localized: "iCloud is not available. Try again when sync is available.")
        case .incompleteSnapshot:
            return String(localized: "iCloud did not return a complete server snapshot.")
        }
    }
}

nonisolated struct ServerPendingMutation: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Payload: Codable, Equatable, Sendable {
        case serverUpsert(Server)
        case serverDelete(Server)
        case workspaceUpsert(Workspace)
        case workspaceDelete(Workspace)

        private enum Kind: String, Codable {
            case serverUpsert
            case serverDelete
            case workspaceUpsert
            case workspaceDelete
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case payload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .serverUpsert:
                self = .serverUpsert(try container.decode(Server.self, forKey: .payload))
            case .serverDelete:
                self = .serverDelete(try container.decode(Server.self, forKey: .payload))
            case .workspaceUpsert:
                self = .workspaceUpsert(try container.decode(Workspace.self, forKey: .payload))
            case .workspaceDelete:
                self = .workspaceDelete(try container.decode(Workspace.self, forKey: .payload))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .serverUpsert(let server):
                try container.encode(Kind.serverUpsert, forKey: .kind)
                try container.encode(server, forKey: .payload)
            case .serverDelete(let server):
                try container.encode(Kind.serverDelete, forKey: .kind)
                try container.encode(server, forKey: .payload)
            case .workspaceUpsert(let workspace):
                try container.encode(Kind.workspaceUpsert, forKey: .kind)
                try container.encode(workspace, forKey: .payload)
            case .workspaceDelete(let workspace):
                try container.encode(Kind.workspaceDelete, forKey: .kind)
                try container.encode(workspace, forKey: .payload)
            }
        }
    }

    let id: UUID
    let payload: Payload
    let createdAt: Date

    init(id: UUID, payload: Payload, createdAt: Date) {
        self.id = id
        self.payload = payload
        self.createdAt = createdAt
    }
}
