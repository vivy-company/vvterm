import Foundation

nonisolated enum StatsPreferencesPendingCloudKitPayloadCodec {
    static let entityType = "statsPreferences"

    static func encode(_ preferences: StatsPreferences) throws -> PendingCloudKitPayloadEnvelope {
        try PendingCloudKitPayloadEnvelope(
            entityType: entityType,
            entityKey: StatsPreferences.recordName,
            operation: .upsert,
            drainPriority: 5,
            value: preferences
        )
    }

    static func decode(_ payload: PendingCloudKitPayloadEnvelope) throws -> StatsPreferences? {
        guard let preferences = try payload.decode(
            StatsPreferences.self,
            entityType: entityType,
            operation: .upsert
        ) else {
            return nil
        }
        try payload.validate(entityKey: StatsPreferences.recordName, drainPriority: 5)
        return preferences
    }

    static func migrateLegacy(
        kind: String,
        encodedValue: Data
    ) throws -> PendingCloudKitPayloadEnvelope? {
        guard kind == "statsPreferencesUpsert" else { return nil }
        return try encode(JSONDecoder().decode(StatsPreferences.self, from: encodedValue))
    }
}

nonisolated extension PendingCloudKitPayloadEnvelope {
    static func statsPreferencesUpsert(_ preferences: StatsPreferences) throws -> Self {
        try StatsPreferencesPendingCloudKitPayloadCodec.encode(preferences)
    }
}
