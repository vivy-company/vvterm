import CloudKit
import Foundation
import os.log

@MainActor
final class ServerCloudKitClient: ServerRemoteRepository, ServerRemoteMutationClient {
    private static let desiredKeys = (
        ServerCloudKitRecordCodec.recordKeys + WorkspaceCloudKitRecordCodec.recordKeys
    ).reduce(into: [String]()) { keys, key in
        if !keys.contains(key) {
            keys.append(key)
        }
    }

    private let transport: any CloudKitRecordChangeTransport
    private let now: () -> Date
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "Server.CloudKit"
    )

    init(
        transport: any CloudKitRecordChangeTransport,
        now: @escaping () -> Date
    ) {
        self.transport = transport
        self.now = now
    }

    var isAvailable: Bool {
        transport.isCloudKitAvailable
    }

    func fetchServerChanges(forceFullFetch: Bool) async throws -> ServerRemoteChanges {
        let rawChanges = try await transport.fetchCloudKitRecordChanges(
            forceFullFetch: forceFullFetch,
            desiredKeys: Self.desiredKeys
        )
        return try decode(rawChanges, fallbackDate: now())
    }

    func acceptServerChanges(_ checkpoint: ServerRemoteChangeCheckpoint) throws {
        try transport.commitCloudKitRecordChanges(
            CloudKitRecordChangeCheckpoint(id: checkpoint.id)
        )
    }

    func saveServer(_ server: Server) async throws {
        let record = ServerCloudKitRecordCodec.record(
            for: server,
            in: transport.cloudKitRecordZoneID,
            now: now()
        )
        try await performMutation(
            record: record,
            successMessage: "Saved server \(server.name) to CloudKit",
            failureMessage: "Failed to save server"
        )
    }

    func deleteServer(_ server: Server) async throws {
        try await deleteRecord(
            named: server.id.uuidString,
            successMessage: "Deleted server \(server.name) from CloudKit",
            failureMessage: "Failed to delete server"
        )
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        let record = WorkspaceCloudKitRecordCodec.record(
            for: workspace,
            in: transport.cloudKitRecordZoneID,
            now: now()
        )
        try await performMutation(
            record: record,
            successMessage: "Saved workspace \(workspace.name) to CloudKit",
            failureMessage: "Failed to save workspace"
        )
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        try await deleteRecord(
            named: workspace.id.uuidString,
            successMessage: "Deleted workspace \(workspace.name) from CloudKit",
            failureMessage: "Failed to delete workspace"
        )
    }

    static func isSchemaError(_ error: Error) -> Bool {
        if let cloudKitError = error as? CKError {
            switch cloudKitError.code {
            case .unknownItem, .invalidArguments:
                return true
            default:
                return false
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("record type")
            || message.contains("field")
            || message.contains("queryable")
    }

    private func decode(
        _ rawChanges: CloudKitRawRecordChanges,
        fallbackDate: Date
    ) throws -> ServerRemoteChanges {
        var serversByID: [UUID: Server] = [:]
        var workspacesByID: [UUID: Workspace] = [:]
        var deletedServerIDs: Set<UUID> = []
        var deletedWorkspaceIDs: Set<UUID> = []

        for change in rawChanges.changes {
            switch change {
            case .record(let record):
                switch record.recordType {
                case ServerCloudKitRecordCodec.recordType:
                    guard let server = ServerCloudKitRecordCodec.server(
                        from: record,
                        now: fallbackDate
                    ) else {
                        throw ServerCloudKitDecodingError.malformedKnownRecord(
                            recordType: record.recordType,
                            recordName: record.recordID.recordName
                        )
                    }
                    serversByID[server.id] = server
                    deletedServerIDs.remove(server.id)
                case WorkspaceCloudKitRecordCodec.recordType:
                    guard let workspace = WorkspaceCloudKitRecordCodec.workspace(
                        from: record,
                        now: fallbackDate
                    ) else {
                        throw ServerCloudKitDecodingError.malformedKnownRecord(
                            recordType: record.recordType,
                            recordName: record.recordID.recordName
                        )
                    }
                    workspacesByID[workspace.id] = workspace
                    deletedWorkspaceIDs.remove(workspace.id)
                default:
                    continue
                }
            case .deletion(let recordID, let recordType):
                switch recordType {
                case ServerCloudKitRecordCodec.recordType:
                    guard let id = UUID(uuidString: recordID.recordName) else {
                        throw ServerCloudKitDecodingError.malformedKnownRecord(
                            recordType: recordType,
                            recordName: recordID.recordName
                        )
                    }
                    serversByID.removeValue(forKey: id)
                    deletedServerIDs.insert(id)
                case WorkspaceCloudKitRecordCodec.recordType:
                    guard let id = UUID(uuidString: recordID.recordName) else {
                        throw ServerCloudKitDecodingError.malformedKnownRecord(
                            recordType: recordType,
                            recordName: recordID.recordName
                        )
                    }
                    workspacesByID.removeValue(forKey: id)
                    deletedWorkspaceIDs.insert(id)
                default:
                    continue
                }
            }
        }

        return ServerRemoteChanges(
            servers: Array(serversByID.values),
            workspaces: Array(workspacesByID.values),
            deletedServerIDs: Array(deletedServerIDs),
            deletedWorkspaceIDs: Array(deletedWorkspaceIDs),
            isFullFetch: rawChanges.isFullFetch,
            checkpoint: ServerRemoteChangeCheckpoint(id: rawChanges.checkpoint.id)
        )
    }

    private func performMutation(
        record: CKRecord,
        successMessage: String,
        failureMessage: String
    ) async throws {
        do {
            try await transport.performCloudKitRecordMutation { [transport] in
                try await transport.upsertCloudKitRecord(record)
            }
            logger.info("\(successMessage)")
        } catch {
            logger.error("\(failureMessage): \(error.localizedDescription)")
            throw error
        }
    }

    private func deleteRecord(
        named recordName: String,
        successMessage: String,
        failureMessage: String
    ) async throws {
        let recordID = CKRecord.ID(
            recordName: recordName,
            zoneID: transport.cloudKitRecordZoneID
        )
        do {
            try await transport.performCloudKitRecordMutation { [transport] in
                try await transport.deleteCloudKitRecord(recordID)
            }
            logger.info("\(successMessage)")
        } catch {
            logger.error("\(failureMessage): \(error.localizedDescription)")
            throw error
        }
    }
}

nonisolated enum ServerCloudKitDecodingError: LocalizedError, Equatable, Sendable {
    case malformedKnownRecord(recordType: String, recordName: String)

    var errorDescription: String? {
        switch self {
        case .malformedKnownRecord(let recordType, let recordName):
            return "The iCloud \(recordType) record \(recordName) is malformed. Sync will retry without advancing its checkpoint."
        }
    }
}
