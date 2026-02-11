import CloudKit
import Foundation
import Combine
import os.log

// MARK: - CloudKit Manager

struct CloudKitChanges {
    let servers: [Server]
    let workspaces: [Workspace]
    let deletedServerIDs: [UUID]
    let deletedWorkspaceIDs: [UUID]
    let isFullFetch: Bool
}

@MainActor
final class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var isAvailable: Bool = false
    @Published var accountStatusDetail: String = String(localized: "Checking...")

    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")
    private let recordZoneName = "VVTermZone"
    private lazy var recordZone = CKRecordZone(zoneName: recordZoneName)
    private var recordZoneID: CKRecordZone.ID { recordZone.zoneID }
    private lazy var changeTokenKey = "com.vivy.vvterm.cloudkit.\(recordZoneName).token"

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
        case disabled

        var description: String {
            switch self {
            case .idle: return String(localized: "Synced")
            case .syncing: return String(localized: "Syncing...")
            case .error(let message): return String(format: String(localized: "Error: %@"), message)
            case .offline: return String(localized: "Offline")
            case .disabled: return String(localized: "Disabled")
            }
        }
    }

    private var accountStatusChecked = false
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }
    private var fetchChangesTask: Task<CloudKitChanges, Error>?
    private var ensureZoneTask: Task<Void, Error>?
    private var zoneReady = false

    private init() {
        container = CKContainer(identifier: "iCloud.app.vivy.VivyTerm")
        database = container.privateCloudDatabase
        Task { await checkAccountStatus() }
    }

    // MARK: - Account Status

    /// Ensures account status is checked before performing operations
    private func ensureAccountStatusChecked() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }
        // Re-check when unavailable so transient account/network states can recover
        guard !accountStatusChecked || !isAvailable else { return }
        await checkAccountStatus()
    }

    private func checkAccountStatus() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }

        do {
            let status = try await container.accountStatus()
            let statusDescription: String
            switch status {
            case .available:
                statusDescription = String(localized: "available")
            case .noAccount:
                statusDescription = String(localized: "noAccount - User not signed into iCloud")
            case .restricted:
                statusDescription = String(localized: "restricted - iCloud access restricted (parental controls, MDM, etc.)")
            case .couldNotDetermine:
                statusDescription = String(localized: "couldNotDetermine - Unable to determine iCloud status")
            case .temporarilyUnavailable:
                statusDescription = String(localized: "temporarilyUnavailable - iCloud temporarily unavailable")
            @unknown default:
                statusDescription = String(format: String(localized: "unknown status: %@"), String(status.rawValue))
            }

            logger.info("CloudKit account status: \(statusDescription)")
            logger.info("Container identifier: \(self.container.containerIdentifier ?? "nil")")

            isAvailable = status == .available
            accountStatusDetail = statusDescription
            accountStatusChecked = true
            if isAvailable {
                if case .offline = syncStatus {
                    syncStatus = .idle
                }
            } else {
                syncStatus = .offline
                logger.warning("CloudKit not available. Status: \(statusDescription)")
            }
        } catch {
            logger.error("CloudKit account status check failed: \(error.localizedDescription)")
            isAvailable = false
            accountStatusDetail = String(format: String(localized: "Error: %@"), error.localizedDescription)
            syncStatus = .error(error.localizedDescription)
            accountStatusChecked = true
        }
    }

    private func applySyncDisabledState() {
        isAvailable = false
        syncStatus = .disabled
        accountStatusDetail = String(localized: "Disabled")
    }

    func handleSyncToggle(_ enabled: Bool) {
        if enabled {
            accountStatusChecked = false
            Task {
                await checkAccountStatus()
                await subscribeToChanges()
            }
        } else {
            applySyncDisabledState()
        }
    }

    // MARK: - Change Fetching (Incremental, No Queries)

    func fetchChanges() async throws -> CloudKitChanges {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        if let task = fetchChangesTask {
            return try await task.value
        }

        let task = Task { try await self.fetchChangesFromCloudKit() }
        fetchChangesTask = task
        defer { fetchChangesTask = nil }

        return try await task.value
    }

    private func fetchChangesFromCloudKit() async throws -> CloudKitChanges {
        syncStatus = .syncing
        defer { syncStatus = .idle }

        let previousToken = loadChangeToken()

        do {
            let changes = try await fetchChangesFromCloudKit(
                previousToken: previousToken,
                isFullFetch: previousToken == nil
            )
            lastSyncDate = Date()
            logger.info(
                "Fetched \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
            )
            return changes
        } catch {
            if isChangeTokenExpired(error) {
                logger.warning("CloudKit change token expired; resetting and performing full fetch")
                clearChangeToken()
                let changes = try await fetchChangesFromCloudKit(previousToken: nil, isFullFetch: true)
                lastSyncDate = Date()
                return changes
            }

            logger.error("Failed to fetch changes: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    private func fetchChangesFromCloudKit(
        previousToken: CKServerChangeToken?,
        isFullFetch: Bool
    ) async throws -> CloudKitChanges {
        let zoneID = recordZoneID
        var token = previousToken
        var moreComing = true

        var servers: [Server] = []
        var workspaces: [Workspace] = []
        var deletedServerIDs: [UUID] = []
        var deletedWorkspaceIDs: [UUID] = []

        while moreComing {
            let batch = try await fetchZoneChanges(zoneID: zoneID, previousToken: token)

            for record in batch.records {
                switch record.recordType {
                case RecordType.server:
                    if let server = Server(from: record) {
                        servers.append(server)
                    }
                case RecordType.workspace:
                    if let workspace = Workspace(from: record) {
                        workspaces.append(workspace)
                    }
                default:
                    break
                }
            }

            for deletion in batch.deletions {
                switch deletion.recordType {
                case RecordType.server:
                    if let id = UUID(uuidString: deletion.recordID.recordName) {
                        deletedServerIDs.append(id)
                    }
                case RecordType.workspace:
                    if let id = UUID(uuidString: deletion.recordID.recordName) {
                        deletedWorkspaceIDs.append(id)
                    }
                default:
                    break
                }
            }

            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        if let token = token {
            saveChangeToken(token)
        }

        return CloudKitChanges(
            servers: servers,
            workspaces: workspaces,
            deletedServerIDs: deletedServerIDs,
            deletedWorkspaceIDs: deletedWorkspaceIDs,
            isFullFetch: isFullFetch
        )
    }

    // MARK: - Server Operations

    func saveServer(_ server: Server) async throws {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let record = server.toRecord(in: recordZoneID)

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
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let recordID = CKRecord.ID(recordName: server.id.uuidString, zoneID: recordZoneID)

        do {
            _ = try await database.modifyRecords(saving: [], deleting: [recordID])
            lastSyncDate = Date()
            logger.info("Deleted server \(server.name) from CloudKit")
        } catch {
            logger.error("Failed to delete server: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Workspace Operations

    func saveWorkspace(_ workspace: Workspace) async throws {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let record = workspace.toRecord(in: recordZoneID)

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
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let recordID = CKRecord.ID(recordName: workspace.id.uuidString, zoneID: recordZoneID)

        do {
            _ = try await database.modifyRecords(saving: [], deleting: [recordID])
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
        await ensureAccountStatusChecked()
        guard isSyncEnabled, isAvailable else { return }

        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true

        let subscription = CKDatabaseSubscription(subscriptionID: "database-changes")
        subscription.notificationInfo = notification

        do {
            _ = try? await database.deleteSubscription(withID: "server-changes")
            _ = try? await database.deleteSubscription(withID: "workspace-changes")
            try await database.save(subscription)
            logger.info("Subscribed to database changes")
        } catch {
            logger.error("Failed to subscribe to database changes: \(error.localizedDescription)")
        }
    }

    // MARK: - Record Fetching (No Queries)

    private struct ZoneChangeBatch {
        let records: [CKRecord]
        let deletions: [Deletion]
        let serverChangeToken: CKServerChangeToken?
        let moreComing: Bool
    }

    private struct Deletion {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: changeTokenKey)
    }

    private func clearChangeToken() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
    }

    private func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .changeTokenExpired
    }

    private func fetchAllRecordsFromCloudKit() async throws -> [CKRecord] {
        try await ensureCustomZone()
        let zoneID = recordZoneID
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        var moreComing = true

        while moreComing {
            let batch = try await fetchZoneChanges(zoneID: zoneID, previousToken: token)
            records.append(contentsOf: batch.records)
            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return records
    }

    private func fetchZoneChanges(
        zoneID: CKRecordZone.ID,
        previousToken: CKServerChangeToken?
    ) async throws -> ZoneChangeBatch {
        let logger = logger
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ZoneChangeBatch, Error>) in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousToken,
                resultsLimit: nil,
                desiredKeys: nil
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            operation.qualityOfService = .userInitiated

            var records: [CKRecord] = []
            var deletions: [Deletion] = []
            var serverChangeToken: CKServerChangeToken?
            var moreComing = false
            var zoneError: Error?

            operation.recordWasChangedBlock = { recordID, recordResult in
                switch recordResult {
                case .success(let record):
                    records.append(record)
                case .failure(let error):
                    logger.error(
                        "Failed to fetch record \(recordID.recordName): \(error.localizedDescription)"
                    )
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                deletions.append(Deletion(recordID: recordID, recordType: recordType))
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let info):
                    serverChangeToken = info.serverChangeToken
                    moreComing = info.moreComing
                case .failure(let error):
                    zoneError = error
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError = zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(
                            returning: ZoneChangeBatch(
                                records: records,
                                deletions: deletions,
                                serverChangeToken: serverChangeToken,
                                moreComing: moreComing
                            )
                        )
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.database.add(operation)
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
        accountStatusChecked = false
        clearChangeToken()
        await checkAccountStatus()
    }

    // MARK: - Cleanup

    /// Delete all records from CloudKit (use with caution!)
    func deleteAllRecords() async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let records = try await fetchAllRecordsFromCloudKit()
        let recordIDs = records
            .filter { $0.recordType == RecordType.server || $0.recordType == RecordType.workspace }
            .map(\.recordID)

        // Batch delete
        if !recordIDs.isEmpty {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
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

        let deletedServers = records.filter { $0.recordType == RecordType.server }.count
        let deletedWorkspaces = records.filter { $0.recordType == RecordType.workspace }.count
        logger.info("Deleted \(deletedServers) servers and \(deletedWorkspaces) workspaces from CloudKit")
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

    // MARK: - Record Zone

    private func ensureCustomZone() async throws {
        if zoneReady {
            return
        }

        if let task = ensureZoneTask {
            try await task.value
            return
        }

        let task = Task { try await self.createZoneIfNeeded() }
        ensureZoneTask = task
        defer { ensureZoneTask = nil }
        try await task.value
        zoneReady = true
    }

    private func createZoneIfNeeded() async throws {
        let results = try await database.recordZones(for: [recordZoneID])
        if let result = results[recordZoneID] {
            switch result {
            case .success:
                return
            case .failure(let error):
                if isZoneNotFound(error) {
                    _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
                    return
                }
                throw error
            }
        }

        _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
    }

    private func isZoneNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .zoneNotFound || ckError.code == .unknownItem
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
