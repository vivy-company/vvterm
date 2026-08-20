import CloudKit

nonisolated struct CloudKitRecordChangeFetchIdentity: Equatable, Sendable {
    let desiredKeys: Set<String>
    let forceFullFetch: Bool

    init(forceFullFetch: Bool, desiredKeys: [String]) {
        self.desiredKeys = Set(desiredKeys)
        self.forceFullFetch = forceFullFetch
    }
}

nonisolated enum CloudKitRecordChangeStreamError: Error, Equatable, Sendable {
    case incompatibleRequestInFlight
    case invalidCheckpoint
    case checkpointPersistenceFailed
}

nonisolated struct CloudKitRecordChangeCheckpoint: Equatable, Sendable {
    let id: UUID
}

nonisolated enum CloudKitRecordChangeRequestDecision: Equatable, Sendable {
    case start
    case coalesce
}

nonisolated enum CloudKitRecordChangeRequestPolicy {
    static func decision(
        for request: CloudKitRecordChangeFetchIdentity,
        inFlight: CloudKitRecordChangeFetchIdentity?
    ) throws -> CloudKitRecordChangeRequestDecision {
        guard let inFlight else { return .start }
        guard request == inFlight else {
            throw CloudKitRecordChangeStreamError.incompatibleRequestInFlight
        }
        return .coalesce
    }

    static func requiresCancellationTeardown(activeWaiterCount: Int) -> Bool {
        activeWaiterCount == 0
    }
}

nonisolated enum CloudKitRecordChangeCheckpointPolicy {
    static func validate(
        _ checkpoint: CloudKitRecordChangeCheckpoint,
        pending: CloudKitRecordChangeCheckpoint?
    ) throws {
        guard checkpoint == pending else {
            throw CloudKitRecordChangeStreamError.invalidCheckpoint
        }
    }
}

@MainActor
enum CloudKitRawRecordChange {
    case record(CKRecord)
    case deletion(recordID: CKRecord.ID, recordType: String)
}

@MainActor
struct CloudKitRawRecordChanges: @unchecked Sendable {
    let changes: [CloudKitRawRecordChange]
    let isFullFetch: Bool
    let checkpoint: CloudKitRecordChangeCheckpoint
}

@MainActor
protocol CloudKitRecordTransport: AnyObject {
    var cloudKitRecordZoneID: CKRecordZone.ID { get }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T
    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord]
    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord
    func upsertCloudKitRecord(_ record: CKRecord) async throws
    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws
    func cloudKitServerRecord(from error: Error) -> CKRecord?
    func isCloudKitRecordMissing(_ error: Error) -> Bool
}

extension CloudKitManager: CloudKitRecordTransport {}

@MainActor
protocol CloudKitRecordChangeTransport: CloudKitRecordTransport {
    var isCloudKitAvailable: Bool { get }
    var cloudKitSyncGeneration: UUID { get }

    /// Reads the zone's single primary change stream without advancing its shared token.
    /// One consumer owns this stream. Every call must use that consumer's normalized keys.
    /// Concurrent calls coalesce only when their keys and fetch mode match exactly.
    func fetchCloudKitRecordChanges(
        forceFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges
    func commitCloudKitRecordChanges(
        _ checkpoint: CloudKitRecordChangeCheckpoint
    ) throws
    func deleteCloudKitRecord(_ recordID: CKRecord.ID) async throws
}

extension CloudKitManager: CloudKitRecordChangeTransport {}
