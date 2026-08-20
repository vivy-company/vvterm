import CloudKit
import Foundation
import os.log

@MainActor
extension CloudKitManager {
    // MARK: - Record Operations

    func prepareSyncMutation(generation: UUID) async throws {
        try await ensureAccountStatusChecked(for: generation)
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
        try requireCurrentGeneration(generation)
    }

    func performSyncOperation<T>(
        generation: UUID,
        _ operation: () async throws -> T
    ) async throws -> T {
        try requireCurrentGeneration(generation)
        let operationID = UUID()
        guard statusStore.syncState.beginOperation(operationID) else {
            throw CloudKitError.notAvailable
        }

        do {
            let result = try await operation()
            try requireCurrentGeneration(generation)
            statusStore.syncState.completeOperation(operationID, with: .success)
            return result
        } catch {
            if isCurrentGeneration(generation) {
                logger.error("CloudKit sync operation failed: \(error.localizedDescription)")
                statusStore.syncState.completeOperation(
                    operationID,
                    with: .failure(error.localizedDescription)
                )
            }
            throw error
        }
    }

    // MARK: - Raw Record Transport

    var cloudKitRecordZoneID: CKRecordZone.ID {
        recordZoneID
    }

    var isCloudKitAvailable: Bool {
        isAvailable
    }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let generation = cloudKitSyncGeneration
        try await prepareSyncMutation(generation: generation)
        let result = try await performSyncOperation(
            generation: generation,
            operation
        )
        statusStore.lastSyncDate = Date()
        return result
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        let generation = cloudKitSyncGeneration
        try await ensureAccountStatusChecked(for: generation)
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
        let records = try await withZoneRetry {
            try await fetchAllRecordsFromCloudKit(
                matchingRecordTypes: recordTypes,
                desiredKeys: desiredKeys
            )
        }
        try requireCurrentGeneration(generation)
        return records
    }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        let generation = cloudKitSyncGeneration
        try await ensureAccountStatusChecked(for: generation)
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
        let record = try await withZoneRetry {
            try await database.record(for: recordID)
        }
        try requireCurrentGeneration(generation)
        return record
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {
        let generation = cloudKitSyncGeneration
        try await withZoneRetry {
            try await saveRecordWithUpsert(record)
        }
        try requireCurrentGeneration(generation)
    }

    func deleteCloudKitRecord(_ recordID: CKRecord.ID) async throws {
        let generation = cloudKitSyncGeneration
        _ = try await withZoneRetry {
            try await database.modifyRecords(saving: [], deleting: [recordID])
        }
        try requireCurrentGeneration(generation)
    }

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {
        let generation = cloudKitSyncGeneration
        try await withZoneRetry {
            try await saveRecord(record, savePolicy: .ifServerRecordUnchanged)
        }
        try requireCurrentGeneration(generation)
    }

    func cloudKitServerRecord(from error: Error) -> CKRecord? {
        extractServerRecord(from: error)
    }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        isUnknownItemError(error)
    }


    // MARK: - Record Fetching (No Queries)

    struct ZoneChangeBatch: @unchecked Sendable {
        let records: [CKRecord]
        let deletions: [Deletion]
        let recordByteCount: Int
        let serverChangeToken: CKServerChangeToken?
        let moreComing: Bool
    }

    struct Deletion {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    func saveChangeToken(_ token: CKServerChangeToken) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
        UserDefaults.standard.set(data, forKey: changeTokenKey)
        guard UserDefaults.standard.data(forKey: changeTokenKey) == data else {
            throw CloudKitRecordChangeStreamError.checkpointPersistenceFailed
        }
    }

    func clearChangeToken() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
    }

    func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .changeTokenExpired
    }

    func fetchAllRecordsFromCloudKit(
        matchingRecordTypes recordTypes: Set<String>? = nil,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        try await ensureCustomZone()
        let zoneID = recordZoneID
        var token: CKServerChangeToken?
        var recordsByID: [String: CKRecord] = [:]
        var moreComing = true
        var budget = CloudKitSyncBudget()

        while moreComing {
            try budget.requireCapacityForNextPage()
            let batch = try await fetchZoneChanges(
                zoneID: zoneID,
                previousToken: token,
                budget: budget,
                desiredKeys: desiredKeys
            )
            try budget.recordBatch(
                records: batch.records.count,
                deletions: batch.deletions.count,
                aggregateBytes: batch.recordByteCount
            )
            for record in batch.records where recordTypes?.contains(record.recordType) != false {
                recordsByID[recordKey(record.recordID, recordType: record.recordType)] = record
            }
            for deletion in batch.deletions {
                recordsByID.removeValue(
                    forKey: recordKey(deletion.recordID, recordType: deletion.recordType)
                )
            }
            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return Array(recordsByID.values)
    }

    func fetchZoneChanges(
        zoneID: CKRecordZone.ID,
        previousToken: CKServerChangeToken?,
        budget: CloudKitSyncBudget,
        desiredKeys: [String]
    ) async throws -> ZoneChangeBatch {
        let logger = logger
        let completion = CloudKitOperationContinuation<ZoneChangeBatch>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                    previousServerChangeToken: previousToken,
                    resultsLimit: min(200, budget.remainingRecords, budget.remainingDeletions),
                    desiredKeys: desiredKeys
                )
                let operation = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [zoneID],
                    configurationsByRecordZoneID: [zoneID: configuration]
                )
                operation.qualityOfService = .userInitiated

                var records: [CKRecord] = []
                var deletions: [Deletion] = []
                var recordByteCount = 0
                var serverChangeToken: CKServerChangeToken?
                var moreComing = false
                var zoneError: Error?

                operation.recordWasChangedBlock = { recordID, recordResult in
                    guard zoneError == nil else { return }
                    switch recordResult {
                    case .success(let record):
                        do {
                            guard records.count < budget.remainingRecords else {
                                throw CloudKitSyncBudgetError.tooManyRecords
                            }
                            let bytes = try CloudKitRecordSizer.byteCount(
                                of: record,
                                limits: budget.limits
                            )
                            let (newByteCount, overflow) = recordByteCount.addingReportingOverflow(bytes)
                            guard !overflow, newByteCount <= budget.remainingBytes else {
                                throw CloudKitSyncBudgetError.aggregateDataTooLarge
                            }
                            recordByteCount = newByteCount
                            records.append(record)
                        } catch {
                            zoneError = error
                            operation.cancel()
                        }
                    case .failure(let error):
                        logger.error(
                            "Failed to fetch record \(recordID.recordName): \(error.localizedDescription)"
                        )
                        zoneError = error
                        operation.cancel()
                    }
                }

                operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                    guard zoneError == nil else { return }
                    guard deletions.count < budget.remainingDeletions else {
                        zoneError = CloudKitSyncBudgetError.tooManyDeletions
                        operation.cancel()
                        return
                    }
                    deletions.append(Deletion(recordID: recordID, recordType: recordType))
                }

                operation.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let info):
                        serverChangeToken = info.serverChangeToken
                        moreComing = info.moreComing
                    case .failure(let error):
                        if zoneError == nil {
                            zoneError = error
                        }
                    }
                }

                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        if let zoneError = zoneError {
                            completion.resume(throwing: zoneError)
                        } else {
                            completion.resume(
                                returning: ZoneChangeBatch(
                                    records: records,
                                    deletions: deletions,
                                    recordByteCount: recordByteCount,
                                    serverChangeToken: serverChangeToken,
                                    moreComing: moreComing
                                )
                            )
                        }
                    case .failure(let error):
                        completion.resume(throwing: zoneError ?? error)
                    }
                }

                completion.install(operation)
                self.database.add(operation)
            }
        } onCancel: {
            completion.cancel()
        }
    }

    func extractServerRecord(from error: Error) -> CKRecord? {
        guard let ckError = error as? CKError else { return nil }

        if ckError.code == .serverRecordChanged {
            return ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partialError in partialErrors.values {
                if let serverRecord = extractServerRecord(from: partialError) {
                    return serverRecord
                }
            }
        }

        return nil
    }

    func isUnknownItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }

        if ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partialErrors.values.contains { isUnknownItemError($0) }
        }

        return false
    }

    // MARK: - Upsert Helper

    /// Save a record using CKModifyRecordsOperation with changedKeys policy
    /// This handles both insert (new record) and update (existing record)
    func saveRecordWithUpsert(_ record: CKRecord) async throws {
        try await saveRecord(record, savePolicy: .changedKeys)
    }

    func saveRecord(
        _ record: CKRecord,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
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

    func recordKey(
        _ recordID: CKRecord.ID,
        recordType: CKRecord.RecordType
    ) -> String {
        "\(recordType):\(recordID.recordName)"
    }
}
