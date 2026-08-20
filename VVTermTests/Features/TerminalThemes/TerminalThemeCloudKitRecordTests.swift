import CloudKit
import XCTest
@testable import VVTerm

final class TerminalThemeCloudKitRecordTests: XCTestCase {
    func testThemeRecordRoundTripPreservesFieldsAndZone() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "TerminalThemeTests",
            ownerName: CKCurrentUserDefaultName
        )
        let theme = TerminalTheme(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Round Trip",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let record = TerminalThemeCloudKitRecordCodec.record(for: theme, in: zoneID)
        let decoded = try XCTUnwrap(TerminalThemeCloudKitRecordCodec.theme(from: record))

        XCTAssertEqual(record.recordType, "TerminalTheme")
        XCTAssertEqual(record.recordID.recordName, theme.id.uuidString)
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(decoded, theme)
    }

    func testThemeRecordWithoutUpdateDateUsesDistantPast() throws {
        let id = UUID()
        let record = CKRecord(
            recordType: "TerminalTheme",
            recordID: CKRecord.ID(recordName: id.uuidString)
        )
        record["name"] = "Legacy Theme" as CKRecordValue
        record["content"] = "background = #000000\nforeground = #FFFFFF\n" as CKRecordValue

        let decoded = try XCTUnwrap(TerminalThemeCloudKitRecordCodec.theme(from: record))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.updatedAt, .distantPast)
        XCTAssertNil(decoded.deletedAt)
    }

    func testPreferenceRecordRoundTripPreservesFieldsAndStableIdentity() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "TerminalThemePreferenceTests",
            ownerName: CKCurrentUserDefaultName
        )
        let preference = TerminalThemePreference(
            darkThemeName: "Aizen Dark",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let record = TerminalThemePreferenceCloudKitRecordCodec.record(
            for: preference,
            in: zoneID
        )
        let decoded = try XCTUnwrap(
            TerminalThemePreferenceCloudKitRecordCodec.preference(from: record)
        )

        XCTAssertEqual(record.recordType, "TerminalThemePreference")
        XCTAssertEqual(record.recordID.recordName, "terminal-theme-preference.v1")
        XCTAssertEqual(record.recordID.zoneID, zoneID)
        XCTAssertEqual(decoded, preference)
    }

    func testPreferenceRecordRejectsUnsafeThemeName() {
        let record = CKRecord(
            recordType: "TerminalThemePreference",
            recordID: CKRecord.ID(
                recordName: TerminalThemePreferenceCloudKitRecordCodec.recordName
            )
        )
        record["darkThemeName"] = "../Outside" as CKRecordValue
        record["lightThemeName"] = "Aizen Light" as CKRecordValue
        record["usePerAppearanceTheme"] = 1 as CKRecordValue

        XCTAssertNil(TerminalThemePreferenceCloudKitRecordCodec.preference(from: record))
    }
}
