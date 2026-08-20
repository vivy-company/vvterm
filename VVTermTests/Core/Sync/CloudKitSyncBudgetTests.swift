import CloudKit
import Foundation
import Testing
@testable import VVTerm

struct CloudKitSyncBudgetTests {
    @Test
    func rejectsRecordBudgetAcrossBatchesWithoutMutatingAcceptedTotals() throws {
        var budget = CloudKitSyncBudget(limits: limits(maximumRecords: 3))
        try budget.recordBatch(records: 2, deletions: 0, aggregateBytes: 20)

        #expect(throws: CloudKitSyncBudgetError.tooManyRecords) {
            try budget.recordBatch(records: 2, deletions: 0, aggregateBytes: 20)
        }
        #expect(budget.recordCount == 2)
        #expect(budget.aggregateBytes == 20)
    }

    @Test
    func rejectsAggregateByteBudgetAcrossBatches() throws {
        var budget = CloudKitSyncBudget(limits: limits(maximumAggregateBytes: 32))
        try budget.recordBatch(records: 1, deletions: 0, aggregateBytes: 24)

        #expect(throws: CloudKitSyncBudgetError.aggregateDataTooLarge) {
            try budget.recordBatch(records: 1, deletions: 0, aggregateBytes: 9)
        }
        #expect(budget.aggregateBytes == 24)
    }

    @Test
    func rejectsOversizedStringsBeforeRecordRetention() {
        let record = CKRecord(recordType: "Server")
        record["name"] = String(repeating: "a", count: 17)

        #expect(throws: CloudKitSyncBudgetError.fieldTooLarge) {
            _ = try CloudKitRecordSizer.byteCount(
                of: record,
                limits: limits(maximumStringBytes: 16)
            )
        }
    }

    @Test
    func rejectsOversizedCollectionsBeforeRecordRetention() {
        let record = CKRecord(recordType: "Server")
        record["tags"] = ["a", "b", "c"]

        #expect(throws: CloudKitSyncBudgetError.collectionTooLarge) {
            _ = try CloudKitRecordSizer.byteCount(
                of: record,
                limits: limits(maximumCollectionCount: 2)
            )
        }
    }

    private func limits(
        maximumRecords: Int = 10,
        maximumDeletions: Int = 10,
        maximumAggregateBytes: Int = 1_024,
        maximumStringBytes: Int = 128,
        maximumDataBytes: Int = 128,
        maximumCollectionCount: Int = 10
    ) -> CloudKitSyncBudget.Limits {
        CloudKitSyncBudget.Limits(
            maximumRecords: maximumRecords,
            maximumDeletions: maximumDeletions,
            maximumAggregateBytes: maximumAggregateBytes,
            maximumStringBytes: maximumStringBytes,
            maximumDataBytes: maximumDataBytes,
            maximumCollectionCount: maximumCollectionCount
        )
    }
}
