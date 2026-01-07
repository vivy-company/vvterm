import CloudKit
import Foundation
import Combine
import os.log

// MARK: - CloudKit Manager

@MainActor
final class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var isAvailable: Bool = false
    @Published var accountStatusDetail: String = "Checking..."

    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")

    // Record types
    private enum RecordType {
        static let server = "Server"
        static let workspace = "Workspace"
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case offline

        var description: String {
            switch self {
            case .idle: return "Synced"
            case .syncing: return "Syncing..."
            case .error(let message): return "Error: \(message)"
            case .offline: return "Offline"
            }
        }
    }

    private init() {
        container = CKContainer(identifier: "iCloud.com.vivy.vivyterm")
        database = container.privateCloudDatabase
        Task { await checkAccountStatus() }
    }

    // MARK: - Account Status

    private func checkAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            let statusDescription: String
            switch status {
            case .available:
                statusDescription = "available"
            case .noAccount:
                statusDescription = "noAccount - User not signed into iCloud"
            case .restricted:
                statusDescription = "restricted - iCloud access restricted (parental controls, MDM, etc.)"
            case .couldNotDetermine:
                statusDescription = "couldNotDetermine - Unable to determine iCloud status"
            case .temporarilyUnavailable:
                statusDescription = "temporarilyUnavailable - iCloud temporarily unavailable"
            @unknown default:
                statusDescription = "unknown status: \(status.rawValue)"
            }

            logger.info("CloudKit account status: \(statusDescription)")
            logger.info("Container identifier: \(self.container.containerIdentifier ?? "nil")")

            isAvailable = status == .available
            accountStatusDetail = statusDescription
            if !isAvailable {
                syncStatus = .offline
                logger.warning("CloudKit not available. Status: \(statusDescription)")
            }
        } catch {
            logger.error("CloudKit account status check failed: \(error.localizedDescription)")
            isAvailable = false
            accountStatusDetail = "Error: \(error.localizedDescription)"
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Server Operations

    func fetchServers() async throws -> [Server] {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let query = CKQuery(recordType: RecordType.server, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        do {
            let (results, _) = try await database.records(matching: query)
            var servers: [Server] = []

            for (_, result) in results {
                if case .success(let record) = result {
                    if let server = Server(from: record) {
                        servers.append(server)
                    }
                }
            }

            lastSyncDate = Date()
            logger.info("Fetched \(servers.count) servers from CloudKit")
            return servers
        } catch {
            logger.error("Failed to fetch servers: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    func saveServer(_ server: Server) async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let record = server.toRecord()

        do {
            try await saveRecordWithUpsert(record)
            lastSyncDate = Date()
            logger.info("Saved server \(server.name) to CloudKit")
        } catch {
            logger.error("Failed to save server: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    func deleteServer(_ server: Server) async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let recordID = CKRecord.ID(recordName: server.id.uuidString)

        do {
            try await database.deleteRecord(withID: recordID)
            lastSyncDate = Date()
            logger.info("Deleted server \(server.name) from CloudKit")
        } catch {
            logger.error("Failed to delete server: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Workspace Operations

    func fetchWorkspaces() async throws -> [Workspace] {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let query = CKQuery(recordType: RecordType.workspace, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]

        do {
            let (results, _) = try await database.records(matching: query)
            var workspaces: [Workspace] = []

            for (_, result) in results {
                if case .success(let record) = result {
                    if let workspace = Workspace(from: record) {
                        workspaces.append(workspace)
                    }
                }
            }

            lastSyncDate = Date()
            logger.info("Fetched \(workspaces.count) workspaces from CloudKit")
            return workspaces
        } catch {
            logger.error("Failed to fetch workspaces: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let record = workspace.toRecord()

        do {
            try await saveRecordWithUpsert(record)
            lastSyncDate = Date()
            logger.info("Saved workspace \(workspace.name) to CloudKit")
        } catch {
            logger.error("Failed to save workspace: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let recordID = CKRecord.ID(recordName: workspace.id.uuidString)

        do {
            try await database.deleteRecord(withID: recordID)
            lastSyncDate = Date()
            logger.info("Deleted workspace \(workspace.name) from CloudKit")
        } catch {
            logger.error("Failed to delete workspace: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Subscriptions

    func subscribeToChanges() async {
        guard isAvailable else { return }

        // Server subscription
        let serverSubscription = CKQuerySubscription(
            recordType: RecordType.server,
            predicate: NSPredicate(value: true),
            subscriptionID: "server-changes",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        serverSubscription.notificationInfo = notification

        do {
            try await database.save(serverSubscription)
            logger.info("Subscribed to server changes")
        } catch {
            logger.error("Failed to subscribe to server changes: \(error.localizedDescription)")
        }

        // Workspace subscription
        let workspaceSubscription = CKQuerySubscription(
            recordType: RecordType.workspace,
            predicate: NSPredicate(value: true),
            subscriptionID: "workspace-changes",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        workspaceSubscription.notificationInfo = notification

        do {
            try await database.save(workspaceSubscription)
            logger.info("Subscribed to workspace changes")
        } catch {
            logger.error("Failed to subscribe to workspace changes: \(error.localizedDescription)")
        }
    }

    // MARK: - Upsert Helper

    /// Save a record using CKModifyRecordsOperation with changedKeys policy
    /// This handles both insert (new record) and update (existing record)
    private func saveRecordWithUpsert(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys  // Insert if new, update if exists
            operation.qualityOfService = .userInitiated

            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    // MARK: - Force Sync

    func forceSync() async {
        lastSyncDate = nil
        await checkAccountStatus()
    }

    // MARK: - Cleanup

    /// Delete all records from CloudKit (use with caution!)
    func deleteAllRecords() async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        syncStatus = .syncing
        defer { syncStatus = .idle }

        // Delete all servers
        let serverQuery = CKQuery(recordType: RecordType.server, predicate: NSPredicate(value: true))
        let (serverResults, _) = try await database.records(matching: serverQuery)
        var serverIDs: [CKRecord.ID] = []
        for (recordID, _) in serverResults {
            serverIDs.append(recordID)
        }

        // Delete all workspaces
        let workspaceQuery = CKQuery(recordType: RecordType.workspace, predicate: NSPredicate(value: true))
        let (workspaceResults, _) = try await database.records(matching: workspaceQuery)
        var workspaceIDs: [CKRecord.ID] = []
        for (recordID, _) in workspaceResults {
            workspaceIDs.append(recordID)
        }

        // Batch delete
        let allIDs = serverIDs + workspaceIDs
        if !allIDs.isEmpty {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: allIDs)
                operation.qualityOfService = .userInitiated

                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                self.database.add(operation)
            }
        }

        logger.info("Deleted \(serverIDs.count) servers and \(workspaceIDs.count) workspaces from CloudKit")
        lastSyncDate = Date()
    }

    // MARK: - Error Helpers

    /// Check if an error is a schema-related error (record type not found)
    static func isSchemaError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .unknownItem, .invalidArguments:
                // unknownItem: record type doesn't exist
                // invalidArguments: field/index issues
                return true
            default:
                return false
            }
        }
        // Check error message for schema-related keywords
        let message = error.localizedDescription.lowercased()
        return message.contains("record type") || message.contains("field") || message.contains("queryable")
    }
}

// MARK: - CloudKit Error

enum CloudKitError: LocalizedError {
    case notAvailable
    case recordNotFound
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "iCloud is not available"
        case .recordNotFound: return "Record not found"
        case .encodingFailed: return "Failed to encode data"
        case .decodingFailed: return "Failed to decode data"
        }
    }
}

// MARK: - Server CloudKit Extensions

extension Server {
    init?(from record: CKRecord) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Server.CloudKit")

        guard let idString = record.recordID.recordName as String?,
              let id = UUID(uuidString: idString) else {
            logger.error("Failed to decode server: invalid recordID '\(record.recordID.recordName)'")
            return nil
        }

        guard let workspaceIdString = record["workspaceId"] as? String,
              let workspaceId = UUID(uuidString: workspaceIdString) else {
            logger.error("Server \(id): missing/invalid workspaceId. Raw value: \(String(describing: record["workspaceId"]))")
            return nil
        }

        guard let name = record["name"] as? String else {
            logger.error("Server \(id): missing name")
            return nil
        }

        guard let host = record["host"] as? String else {
            logger.error("Server \(id): missing host")
            return nil
        }

        guard let port = record["port"] as? Int else {
            logger.error("Server \(id): missing/invalid port. Raw value: \(String(describing: record["port"]))")
            return nil
        }

        guard let username = record["username"] as? String else {
            logger.error("Server \(id): missing username")
            return nil
        }

        guard let authMethodRaw = record["authMethod"] as? String,
              let authMethod = AuthMethod(rawValue: authMethodRaw) else {
            logger.error("Server \(id): invalid authMethod. Raw value: \(String(describing: record["authMethod"]))")
            return nil
        }

        logger.info("Successfully decoded server: \(name) (id: \(id), workspaceId: \(workspaceId))")

        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.tags = record["tags"] as? [String] ?? []
        self.notes = record["notes"] as? String
        self.lastConnected = record["lastConnected"] as? Date
        self.isFavorite = record["isFavorite"] as? Bool ?? false
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.updatedAt = record["updatedAt"] as? Date ?? Date()
        self.keychainCredentialId = record["keychainCredentialId"] as? String ?? id.uuidString

        // Decode environment
        if let envData = record["environment"] as? Data,
           let environment = try? JSONDecoder().decode(ServerEnvironment.self, from: envData) {
            self.environment = environment
        } else {
            self.environment = .production
        }
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let record = CKRecord(recordType: "Server", recordID: recordID)

        record["workspaceId"] = workspaceId.uuidString
        record["name"] = name
        record["host"] = host
        record["port"] = port
        record["username"] = username
        record["authMethod"] = authMethod.rawValue
        // CloudKit rejects empty arrays for new fields - only set if non-empty
        if !tags.isEmpty {
            record["tags"] = tags
        }
        record["notes"] = notes
        record["lastConnected"] = lastConnected
        record["isFavorite"] = isFavorite
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["keychainCredentialId"] = keychainCredentialId

        if let envData = try? JSONEncoder().encode(environment) {
            record["environment"] = envData
        }

        return record
    }
}

// MARK: - Workspace CloudKit Extensions

extension Workspace {
    init?(from record: CKRecord) {
        guard
            let idString = record.recordID.recordName as String?,
            let id = UUID(uuidString: idString),
            let name = record["name"] as? String,
            let colorHex = record["colorHex"] as? String
        else {
            return nil
        }

        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = record["icon"] as? String
        self.order = record["order"] as? Int ?? 0
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.updatedAt = record["updatedAt"] as? Date ?? Date()

        if let lastEnvIdString = record["lastSelectedEnvironmentId"] as? String {
            self.lastSelectedEnvironmentId = UUID(uuidString: lastEnvIdString)
        } else {
            self.lastSelectedEnvironmentId = nil
        }

        if let lastServerIdString = record["lastSelectedServerId"] as? String {
            self.lastSelectedServerId = UUID(uuidString: lastServerIdString)
        } else {
            self.lastSelectedServerId = nil
        }

        // Decode environments
        if let envData = record["environments"] as? Data,
           let environments = try? JSONDecoder().decode([ServerEnvironment].self, from: envData) {
            self.environments = environments
        } else {
            self.environments = ServerEnvironment.builtInEnvironments
        }
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let record = CKRecord(recordType: "Workspace", recordID: recordID)

        record["name"] = name
        record["colorHex"] = colorHex
        record["icon"] = icon
        record["order"] = order
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["lastSelectedEnvironmentId"] = lastSelectedEnvironmentId?.uuidString
        record["lastSelectedServerId"] = lastSelectedServerId?.uuidString

        if let envData = try? JSONEncoder().encode(environments) {
            record["environments"] = envData
        }

        return record
    }
}
