import Foundation

nonisolated enum TerminalThemePendingCloudKitPayloadCodec {
    static let themeEntityType = "terminalTheme"
    static let preferenceEntityType = "terminalThemePreference"

    static func encodeTheme(_ theme: TerminalTheme) throws -> PendingCloudKitPayloadEnvelope {
        try PendingCloudKitPayloadEnvelope(
            entityType: themeEntityType,
            entityKey: theme.id.uuidString,
            operation: .upsert,
            drainPriority: 2,
            value: theme
        )
    }

    static func encodePreference(
        _ preference: TerminalThemePreference
    ) throws -> PendingCloudKitPayloadEnvelope {
        try PendingCloudKitPayloadEnvelope(
            entityType: preferenceEntityType,
            entityKey: TerminalThemePreference.recordName,
            operation: .upsert,
            drainPriority: 3,
            value: preference
        )
    }

    static func decodeTheme(_ payload: PendingCloudKitPayloadEnvelope) throws -> TerminalTheme? {
        guard let theme = try payload.decode(
            TerminalTheme.self,
            entityType: themeEntityType,
            operation: .upsert
        ) else {
            return nil
        }
        try payload.validate(entityKey: theme.id.uuidString, drainPriority: 2)
        return theme
    }

    static func decodePreference(
        _ payload: PendingCloudKitPayloadEnvelope
    ) throws -> TerminalThemePreference? {
        guard let preference = try payload.decode(
            TerminalThemePreference.self,
            entityType: preferenceEntityType,
            operation: .upsert
        ) else {
            return nil
        }
        try payload.validate(
            entityKey: TerminalThemePreference.recordName,
            drainPriority: 3
        )
        return preference
    }

    static func migrateLegacy(
        kind: String,
        encodedValue: Data
    ) throws -> PendingCloudKitPayloadEnvelope? {
        switch kind {
        case "terminalThemeUpsert":
            return try encodeTheme(JSONDecoder().decode(TerminalTheme.self, from: encodedValue))
        case "terminalThemePreferenceUpsert":
            return try encodePreference(
                JSONDecoder().decode(TerminalThemePreference.self, from: encodedValue)
            )
        default:
            return nil
        }
    }
}

nonisolated extension PendingCloudKitPayloadEnvelope {
    static func terminalThemeUpsert(_ theme: TerminalTheme) throws -> Self {
        try TerminalThemePendingCloudKitPayloadCodec.encodeTheme(theme)
    }

    static func terminalThemePreferenceUpsert(_ preference: TerminalThemePreference) throws -> Self {
        try TerminalThemePendingCloudKitPayloadCodec.encodePreference(preference)
    }
}
