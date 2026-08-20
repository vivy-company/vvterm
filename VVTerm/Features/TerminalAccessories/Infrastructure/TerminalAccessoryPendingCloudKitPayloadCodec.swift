import Foundation

nonisolated enum TerminalAccessoryPendingCloudKitPayloadCodec {
    static let entityType = "terminalAccessoryProfile"

    static func encode(
        _ profile: TerminalAccessoryProfile
    ) throws -> PendingCloudKitPayloadEnvelope {
        try PendingCloudKitPayloadEnvelope(
            entityType: entityType,
            entityKey: TerminalAccessoryProfile.recordName,
            operation: .upsert,
            drainPriority: 4,
            value: profile
        )
    }

    static func decode(
        _ payload: PendingCloudKitPayloadEnvelope
    ) throws -> TerminalAccessoryProfile? {
        guard let profile = try payload.decode(
            TerminalAccessoryProfile.self,
            entityType: entityType,
            operation: .upsert
        ) else {
            return nil
        }
        try payload.validate(
            entityKey: TerminalAccessoryProfile.recordName,
            drainPriority: 4
        )
        return profile
    }

    static func migrateLegacy(
        kind: String,
        encodedValue: Data
    ) throws -> PendingCloudKitPayloadEnvelope? {
        guard kind == "terminalAccessoryProfileUpsert" else { return nil }
        return try encode(
            JSONDecoder().decode(TerminalAccessoryProfile.self, from: encodedValue)
        )
    }
}

nonisolated extension PendingCloudKitPayloadEnvelope {
    static func terminalAccessoryProfileUpsert(
        _ profile: TerminalAccessoryProfile
    ) throws -> Self {
        try TerminalAccessoryPendingCloudKitPayloadCodec.encode(profile)
    }
}
