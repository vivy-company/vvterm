//
//  TerminalTheme.swift
//  VVTerm
//

import Foundation
import CloudKit

struct TerminalTheme: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var content: String
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }
}

struct TerminalThemePreference: Codable, Equatable {
    static let recordName = "terminal-theme-preference.v1"

    var darkThemeName: String
    var lightThemeName: String
    var usePerAppearanceTheme: Bool
    var updatedAt: Date
}

// MARK: - CloudKit Serialization

extension TerminalTheme {
    init?(from record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let content = record["content"] as? String
        else {
            return nil
        }

        self.id = id
        self.name = name
        self.content = content
        self.updatedAt = record["updatedAt"] as? Date ?? Date.distantPast
        self.deletedAt = record["deletedAt"] as? Date
    }

    func toRecord(in zoneID: CKRecordZone.ID? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID ?? CKRecordZone.default().zoneID)
        let record = CKRecord(recordType: "TerminalTheme", recordID: recordID)
        record["name"] = name
        record["content"] = content
        record["updatedAt"] = updatedAt
        record["deletedAt"] = deletedAt
        return record
    }
}

extension TerminalThemePreference {
    init?(from record: CKRecord) {
        guard
            let darkThemeName = record["darkThemeName"] as? String,
            let lightThemeName = record["lightThemeName"] as? String,
            let usePerAppearanceTheme = record["usePerAppearanceTheme"] as? Int
        else {
            return nil
        }

        self.darkThemeName = darkThemeName
        self.lightThemeName = lightThemeName
        self.usePerAppearanceTheme = usePerAppearanceTheme != 0
        self.updatedAt = record["updatedAt"] as? Date ?? Date.distantPast
    }

    func toRecord(in zoneID: CKRecordZone.ID? = nil) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName,
            zoneID: zoneID ?? CKRecordZone.default().zoneID
        )
        let record = CKRecord(recordType: "TerminalThemePreference", recordID: recordID)
        record["darkThemeName"] = darkThemeName
        record["lightThemeName"] = lightThemeName
        record["usePerAppearanceTheme"] = usePerAppearanceTheme ? 1 : 0
        record["updatedAt"] = updatedAt
        return record
    }
}
