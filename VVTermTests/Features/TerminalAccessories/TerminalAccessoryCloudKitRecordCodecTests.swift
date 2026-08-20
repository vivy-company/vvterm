import CloudKit
import Foundation
import XCTest
@testable import VVTerm

final class TerminalAccessoryCloudKitRecordCodecTests: XCTestCase {
    func testRecordRoundTripPreservesNormalizedProfileAndStableIdentity() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "TerminalAccessoryCodecTests",
            ownerName: CKCurrentUserDefaultName
        )
        var profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "device-a")
        profile.updatedAt = Date(timeIntervalSince1970: 100)
        profile.layout.updatedAt = Date(timeIntervalSince1970: 90)

        let recordID = TerminalAccessoryCloudKitRecordCodec.recordID(in: zoneID)
        let record = try TerminalAccessoryCloudKitRecordCodec.record(
            for: profile,
            recordID: recordID
        )
        let decoded = try XCTUnwrap(
            TerminalAccessoryCloudKitRecordCodec.profile(from: record)
        )

        XCTAssertEqual(record.recordType, "UserPreference")
        XCTAssertEqual(record.recordID.recordName, "terminalAccessory.v1")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(decoded, profile.normalized())
    }

    func testRecordMetadataOverridesOlderPayloadMetadata() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "TerminalAccessoryMetadataTests",
            ownerName: CKCurrentUserDefaultName
        )
        var profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "payload-writer")
        profile.updatedAt = Date(timeIntervalSince1970: 10)
        let record = try TerminalAccessoryCloudKitRecordCodec.record(
            for: profile,
            recordID: TerminalAccessoryCloudKitRecordCodec.recordID(in: zoneID)
        )
        record["schemaVersion"] = 7
        record["updatedAt"] = Date(timeIntervalSince1970: 20)
        record["lastWriterDeviceId"] = "record-writer"

        let decoded = try XCTUnwrap(
            TerminalAccessoryCloudKitRecordCodec.profile(from: record)
        )

        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.updatedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(decoded.lastWriterDeviceId, "record-writer")
    }

    func testMergeKeepsNewerLayoutAndNewerProfileWriter() {
        var local = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "local")
        local.layout.activeItems = Array(TerminalAccessoryProfile.defaultActiveItems.prefix(4))
        local.layout.updatedAt = Date(timeIntervalSince1970: 30)
        local.updatedAt = Date(timeIntervalSince1970: 30)

        var remote = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "remote")
        remote.layout.activeItems = Array(TerminalAccessoryProfile.defaultActiveItems.suffix(4))
        remote.layout.updatedAt = Date(timeIntervalSince1970: 20)
        remote.updatedAt = Date(timeIntervalSince1970: 40)

        let merged = TerminalAccessoryCloudKitRecordCodec.merge(
            local: local,
            remote: remote
        )

        XCTAssertEqual(merged.layout.activeItems, local.layout.activeItems)
        XCTAssertEqual(merged.updatedAt, remote.updatedAt)
        XCTAssertEqual(merged.lastWriterDeviceId, "remote")
    }

    func testInvalidPayloadIsRejected() {
        let record = CKRecord(
            recordType: TerminalAccessoryCloudKitRecordCodec.recordType,
            recordID: CKRecord.ID(recordName: TerminalAccessoryCloudKitRecordCodec.recordName)
        )
        record["payload"] = Data("not-json".utf8)

        XCTAssertNil(TerminalAccessoryCloudKitRecordCodec.profile(from: record))
    }
}
