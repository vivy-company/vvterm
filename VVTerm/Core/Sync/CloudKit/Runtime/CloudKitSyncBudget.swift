import CloudKit
import Foundation

nonisolated struct CloudKitSyncBudget: Sendable {
    struct Limits: Sendable {
        let maximumRecords: Int
        let maximumDeletions: Int
        let maximumAggregateBytes: Int
        let maximumStringBytes: Int
        let maximumDataBytes: Int
        let maximumCollectionCount: Int

        static let standard = Limits(
            maximumRecords: 10_000,
            maximumDeletions: 10_000,
            maximumAggregateBytes: 32 * 1024 * 1024,
            maximumStringBytes: 256 * 1024,
            maximumDataBytes: 512 * 1024,
            maximumCollectionCount: 256
        )
    }

    let limits: Limits
    private(set) var recordCount = 0
    private(set) var deletionCount = 0
    private(set) var aggregateBytes = 0

    init(limits: Limits = .standard) {
        self.limits = limits
    }

    var remainingRecords: Int { limits.maximumRecords - recordCount }
    var remainingDeletions: Int { limits.maximumDeletions - deletionCount }
    var remainingBytes: Int { limits.maximumAggregateBytes - aggregateBytes }

    mutating func recordBatch(
        records: Int,
        deletions: Int,
        aggregateBytes bytes: Int
    ) throws {
        let newRecordCount = try Self.checkedSum(recordCount, records)
        let newDeletionCount = try Self.checkedSum(deletionCount, deletions)
        let newAggregateBytes = try Self.checkedSum(aggregateBytes, bytes)

        guard newRecordCount <= limits.maximumRecords else {
            throw CloudKitSyncBudgetError.tooManyRecords
        }
        guard newDeletionCount <= limits.maximumDeletions else {
            throw CloudKitSyncBudgetError.tooManyDeletions
        }
        guard newAggregateBytes <= limits.maximumAggregateBytes else {
            throw CloudKitSyncBudgetError.aggregateDataTooLarge
        }

        recordCount = newRecordCount
        deletionCount = newDeletionCount
        aggregateBytes = newAggregateBytes
    }

    func requireCapacityForNextPage() throws {
        guard remainingRecords > 0 else {
            throw CloudKitSyncBudgetError.tooManyRecords
        }
        guard remainingDeletions > 0 else {
            throw CloudKitSyncBudgetError.tooManyDeletions
        }
        guard remainingBytes > 0 else {
            throw CloudKitSyncBudgetError.aggregateDataTooLarge
        }
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard rhs >= 0 else { throw CloudKitSyncBudgetError.invalidSize }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CloudKitSyncBudgetError.invalidSize }
        return sum
    }
}

nonisolated enum CloudKitSyncBudgetError: LocalizedError, Equatable {
    case tooManyRecords
    case tooManyDeletions
    case aggregateDataTooLarge
    case fieldTooLarge
    case collectionTooLarge
    case unsupportedFieldType
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .tooManyRecords:
            return "iCloud sync returned too many records"
        case .tooManyDeletions:
            return "iCloud sync returned too many deletions"
        case .aggregateDataTooLarge:
            return "iCloud sync data is too large"
        case .fieldTooLarge:
            return "An iCloud sync field is too large"
        case .collectionTooLarge:
            return "An iCloud sync collection has too many items"
        case .unsupportedFieldType:
            return "An iCloud sync field has an unsupported type"
        case .invalidSize:
            return "An iCloud sync size is invalid"
        }
    }
}

nonisolated enum CloudKitRecordSizer {
    static func byteCount(
        of record: CKRecord,
        limits: CloudKitSyncBudget.Limits
    ) throws -> Int {
        let keys = record.allKeys()
        guard keys.count <= limits.maximumCollectionCount else {
            throw CloudKitSyncBudgetError.collectionTooLarge
        }

        var total = record.recordID.recordName.utf8.count
        for key in keys {
            total = try checkedSum(total, key.utf8.count)
            guard let value = record[key] else { continue }
            total = try checkedSum(total, try byteCount(of: value, limits: limits))
        }
        return total
    }

    private static func byteCount(
        of value: Any,
        limits: CloudKitSyncBudget.Limits
    ) throws -> Int {
        if let string = value as? String {
            let count = string.utf8.count
            guard count <= limits.maximumStringBytes else {
                throw CloudKitSyncBudgetError.fieldTooLarge
            }
            return count
        }

        if let data = value as? Data {
            guard data.count <= limits.maximumDataBytes else {
                throw CloudKitSyncBudgetError.fieldTooLarge
            }
            return data.count
        }

        if let strings = value as? [String] {
            guard strings.count <= limits.maximumCollectionCount else {
                throw CloudKitSyncBudgetError.collectionTooLarge
            }
            return try strings.reduce(into: 0) { total, string in
                total = try checkedSum(total, try byteCount(of: string, limits: limits))
            }
        }

        if let values = value as? [Any] {
            guard values.count <= limits.maximumCollectionCount else {
                throw CloudKitSyncBudgetError.collectionTooLarge
            }
            return try values.reduce(into: 0) { total, element in
                total = try checkedSum(total, try byteCount(of: element, limits: limits))
            }
        }

        if value is NSNumber || value is Date {
            return MemoryLayout<UInt64>.size
        }

        throw CloudKitSyncBudgetError.unsupportedFieldType
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CloudKitSyncBudgetError.invalidSize }
        return sum
    }
}
