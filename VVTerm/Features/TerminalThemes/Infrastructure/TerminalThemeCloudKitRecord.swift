import CloudKit
import Foundation

nonisolated enum TerminalThemeCloudKitRecordCodec {
    static let recordType = "TerminalTheme"
    static let recordKeys = ["name", "content", "updatedAt", "deletedAt"]

    static func theme(from record: CKRecord) -> TerminalTheme? {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let content = record["content"] as? String,
            let validatedName = try? TerminalThemeValidator.validateAndNormalizeThemeName(name)
        else {
            return nil
        }

        return TerminalTheme(
            id: id,
            name: validatedName,
            content: content,
            updatedAt: record["updatedAt"] as? Date ?? Date.distantPast,
            deletedAt: record["deletedAt"] as? Date
        )
    }

    static func record(for theme: TerminalTheme, in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: theme.id.uuidString,
            zoneID: zoneID
        )
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["name"] = theme.name
        record["content"] = theme.content
        record["updatedAt"] = theme.updatedAt
        record["deletedAt"] = theme.deletedAt
        return record
    }
}

nonisolated enum TerminalThemePreferenceCloudKitRecordCodec {
    static let recordType = "TerminalThemePreference"
    static let recordName = TerminalThemePreference.recordName
    static let recordKeys = [
        "darkThemeName", "lightThemeName", "usePerAppearanceTheme", "updatedAt"
    ]

    static func preference(from record: CKRecord) -> TerminalThemePreference? {
        guard
            let darkThemeName = record["darkThemeName"] as? String,
            let lightThemeName = record["lightThemeName"] as? String,
            let usePerAppearanceTheme = record["usePerAppearanceTheme"] as? Int,
            let validatedDarkThemeName = try? TerminalThemeValidator.validateAndNormalizeThemeName(
                darkThemeName
            ),
            let validatedLightThemeName = try? TerminalThemeValidator.validateAndNormalizeThemeName(
                lightThemeName
            )
        else {
            return nil
        }

        return TerminalThemePreference(
            darkThemeName: validatedDarkThemeName,
            lightThemeName: validatedLightThemeName,
            usePerAppearanceTheme: usePerAppearanceTheme != 0,
            updatedAt: record["updatedAt"] as? Date ?? Date.distantPast
        )
    }

    static func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    static func record(
        for preference: TerminalThemePreference,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: recordName,
            zoneID: zoneID
        )
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["darkThemeName"] = preference.darkThemeName
        record["lightThemeName"] = preference.lightThemeName
        record["usePerAppearanceTheme"] = preference.usePerAppearanceTheme ? 1 : 0
        record["updatedAt"] = preference.updatedAt
        return record
    }
}

extension TerminalThemePreference {
    nonisolated static let recordName = "terminal-theme-preference.v1"
}
