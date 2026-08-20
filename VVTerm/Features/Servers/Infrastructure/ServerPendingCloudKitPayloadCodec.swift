import Foundation

nonisolated enum ServerPendingCloudKitPayloadCodec {
    static let serverEntityType = "server"
    static let workspaceEntityType = "workspace"

    static func encode(_ payload: ServerPendingMutation.Payload) throws -> PendingCloudKitPayloadEnvelope {
        switch payload {
        case .serverUpsert(let server):
            return try PendingCloudKitPayloadEnvelope(
                entityType: serverEntityType,
                entityKey: server.id.uuidString,
                operation: .upsert,
                drainPriority: 1,
                value: server
            )
        case .serverDelete(let server):
            return try PendingCloudKitPayloadEnvelope(
                entityType: serverEntityType,
                entityKey: server.id.uuidString,
                operation: .delete,
                drainPriority: 6,
                value: server
            )
        case .workspaceUpsert(let workspace):
            return try PendingCloudKitPayloadEnvelope(
                entityType: workspaceEntityType,
                entityKey: workspace.id.uuidString,
                operation: .upsert,
                drainPriority: 0,
                value: workspace
            )
        case .workspaceDelete(let workspace):
            return try PendingCloudKitPayloadEnvelope(
                entityType: workspaceEntityType,
                entityKey: workspace.id.uuidString,
                operation: .delete,
                drainPriority: 7,
                value: workspace
            )
        }
    }

    static func decode(_ payload: PendingCloudKitPayloadEnvelope) throws -> ServerPendingMutation.Payload? {
        switch (payload.entityType, payload.operation) {
        case (serverEntityType, .upsert):
            let server = try JSONDecoder().decode(Server.self, from: payload.encodedValue)
            try payload.validate(entityKey: server.id.uuidString, drainPriority: 1)
            return .serverUpsert(server)
        case (serverEntityType, .delete):
            let server = try JSONDecoder().decode(Server.self, from: payload.encodedValue)
            try payload.validate(entityKey: server.id.uuidString, drainPriority: 6)
            return .serverDelete(server)
        case (workspaceEntityType, .upsert):
            let workspace = try JSONDecoder().decode(Workspace.self, from: payload.encodedValue)
            try payload.validate(entityKey: workspace.id.uuidString, drainPriority: 0)
            return .workspaceUpsert(workspace)
        case (workspaceEntityType, .delete):
            let workspace = try JSONDecoder().decode(Workspace.self, from: payload.encodedValue)
            try payload.validate(entityKey: workspace.id.uuidString, drainPriority: 7)
            return .workspaceDelete(workspace)
        default:
            return nil
        }
    }

    static func contains(_ payload: PendingCloudKitPayloadEnvelope) -> Bool {
        do {
            return try decode(payload) != nil
        } catch {
            return false
        }
    }

    static func migrateLegacy(
        kind: String,
        encodedValue: Data
    ) throws -> PendingCloudKitPayloadEnvelope? {
        switch kind {
        case "serverUpsert":
            return try encode(.serverUpsert(JSONDecoder().decode(Server.self, from: encodedValue)))
        case "serverDelete":
            return try encode(.serverDelete(JSONDecoder().decode(Server.self, from: encodedValue)))
        case "workspaceUpsert":
            return try encode(
                .workspaceUpsert(JSONDecoder().decode(Workspace.self, from: encodedValue))
            )
        case "workspaceDelete":
            return try encode(
                .workspaceDelete(JSONDecoder().decode(Workspace.self, from: encodedValue))
            )
        default:
            return nil
        }
    }
}

nonisolated extension PendingCloudKitPayloadEnvelope {
    static func serverUpsert(_ server: Server) throws -> Self {
        try ServerPendingCloudKitPayloadCodec.encode(.serverUpsert(server))
    }

    static func serverDelete(_ server: Server) throws -> Self {
        try ServerPendingCloudKitPayloadCodec.encode(.serverDelete(server))
    }

    static func workspaceUpsert(_ workspace: Workspace) throws -> Self {
        try ServerPendingCloudKitPayloadCodec.encode(.workspaceUpsert(workspace))
    }

    static func workspaceDelete(_ workspace: Workspace) throws -> Self {
        try ServerPendingCloudKitPayloadCodec.encode(.workspaceDelete(workspace))
    }
}
