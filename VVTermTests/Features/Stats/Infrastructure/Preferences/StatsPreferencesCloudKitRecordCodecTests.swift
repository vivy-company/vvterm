import CloudKit
import Foundation
import XCTest
@testable import VVTerm

final class StatsPreferencesCloudKitRecordCodecTests: XCTestCase {
    func testRecordRoundTripPreservesNormalizedPreferencesAndStableIdentity() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "StatsPreferencesCodecTests",
            ownerName: CKCurrentUserDefaultName
        )
        let preferences = StatsPreferences(
            style: .classic,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSince1970: 100),
            lastWriterDeviceId: "device-a"
        )

        let recordID = StatsPreferencesCloudKitRecordCodec.recordID(in: zoneID)
        let record = try StatsPreferencesCloudKitRecordCodec.record(
            for: preferences,
            recordID: recordID
        )
        let decoded = try XCTUnwrap(
            StatsPreferencesCloudKitRecordCodec.preferences(from: record)
        )

        XCTAssertEqual(record.recordType, "UserPreference")
        XCTAssertEqual(record.recordID.recordName, "statsPreferences.v1")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(decoded, preferences.normalized())
    }

    func testRecordMetadataOverridesOlderPayloadMetadata() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "StatsPreferencesMetadataTests",
            ownerName: CKCurrentUserDefaultName
        )
        let preferences = StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSince1970: 10),
            lastWriterDeviceId: "payload-writer"
        )
        let record = try StatsPreferencesCloudKitRecordCodec.record(
            for: preferences,
            recordID: StatsPreferencesCloudKitRecordCodec.recordID(in: zoneID)
        )
        record["schemaVersion"] = 7
        record["updatedAt"] = Date(timeIntervalSince1970: 20)
        record["lastWriterDeviceId"] = "record-writer"

        let decoded = try XCTUnwrap(
            StatsPreferencesCloudKitRecordCodec.preferences(from: record)
        )

        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.updatedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(decoded.lastWriterDeviceId, "record-writer")
    }

    func testMergeUsesProfileTimestampForStyleAndBlockTimestampForVisibility() {
        let local = makePreferences(
            style: .cardsCompact,
            profileTime: 10,
            cpuVisible: false,
            cpuTime: 30,
            writer: "local"
        )
        let remote = makePreferences(
            style: .classic,
            profileTime: 20,
            cpuVisible: true,
            cpuTime: 15,
            writer: "remote"
        )

        let merged = StatsPreferencesCloudKitRecordCodec.merge(
            local: local,
            remote: remote
        )

        XCTAssertEqual(merged.style, .classic)
        XCTAssertFalse(merged.isBlockVisible(.cpu))
        XCTAssertEqual(merged.lastWriterDeviceId, "remote")
    }

    func testInvalidPayloadIsRejected() {
        let record = CKRecord(
            recordType: StatsPreferencesCloudKitRecordCodec.recordType,
            recordID: CKRecord.ID(recordName: StatsPreferencesCloudKitRecordCodec.recordName)
        )
        record["payload"] = Data("not-json".utf8)

        XCTAssertNil(StatsPreferencesCloudKitRecordCodec.preferences(from: record))
    }

    private func makePreferences(
        style: StatsPreferences.Style,
        profileTime: TimeInterval,
        cpuVisible: Bool,
        cpuTime: TimeInterval,
        writer: String
    ) -> StatsPreferences {
        var blocks = StatsPreferences.defaultBlocks
        let cpuIndex = blocks.firstIndex(where: { $0.id == .cpu })!
        blocks[cpuIndex].isVisible = cpuVisible
        blocks[cpuIndex].updatedAt = Date(timeIntervalSince1970: cpuTime)
        return StatsPreferences(
            style: style,
            blocks: blocks,
            updatedAt: Date(timeIntervalSince1970: profileTime),
            lastWriterDeviceId: writer
        )
    }
}
