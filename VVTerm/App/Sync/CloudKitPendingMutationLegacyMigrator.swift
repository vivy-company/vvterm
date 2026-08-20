import Foundation

nonisolated struct CloudKitPendingMutationLegacyMigrator: PendingCloudKitLegacyMutationMigrating {
    func migrate(
        recordData: Data
    ) -> Result<PendingCloudKitMutation, PendingCloudKitMutationQuarantineReason>? {
        guard let object = try? JSONSerialization.jsonObject(with: recordData),
              let record = object as? [String: Any],
              let metadata = try? JSONDecoder().decode(LegacyMetadata.self, from: recordData) else {
            return nil
        }

        if let payloadContainer = record["payload"] as? [String: Any],
           let kind = payloadContainer["kind"] as? String,
           let value = payloadContainer["payload"] {
            return migrateCurrentLegacyPayload(
                kind: kind,
                value: value,
                metadata: metadata
            )
        }

        return migrateUnionLegacyPayload(record: record, metadata: metadata)
    }

    private func migrateCurrentLegacyPayload(
        kind: String,
        value: Any,
        metadata: LegacyMetadata
    ) -> Result<PendingCloudKitMutation, PendingCloudKitMutationQuarantineReason> {
        guard let valueData = encodedJSONValue(value) else {
            return .failure(.unreadableLegacyRecord)
        }

        do {
            guard let payload = try decodeFeaturePayload(kind: kind, encodedValue: valueData) else {
                return .failure(.unreadableLegacyRecord)
            }
            return .success(metadata.mutation(payload: payload))
        } catch {
            return .failure(.unreadableLegacyRecord)
        }
    }

    private func migrateUnionLegacyPayload(
        record: [String: Any],
        metadata: LegacyMetadata
    ) -> Result<PendingCloudKitMutation, PendingCloudKitMutationQuarantineReason>? {
        guard let entity = record["entity"] as? String,
              let operation = record["operation"] as? String,
              let entityKey = record["entityKey"] as? String else {
            return nil
        }

        let route: LegacyUnionRoute
        switch (entity, operation) {
        case ("server", "upsert"):
            route = .init(field: "server", kind: "serverUpsert")
        case ("server", "delete"):
            route = .init(field: "server", kind: "serverDelete")
        case ("workspace", "upsert"):
            route = .init(field: "workspace", kind: "workspaceUpsert")
        case ("workspace", "delete"):
            route = .init(field: "workspace", kind: "workspaceDelete")
        case ("terminalTheme", "upsert"), ("terminalTheme", "delete"):
            // Legacy theme deletes used the same save path as tombstone upserts.
            route = .init(field: "terminalTheme", kind: "terminalThemeUpsert")
        case ("terminalThemePreference", "upsert"):
            route = .init(
                field: "terminalThemePreference",
                kind: "terminalThemePreferenceUpsert"
            )
        case ("terminalAccessoryProfile", "upsert"):
            route = .init(
                field: "terminalAccessoryProfile",
                kind: "terminalAccessoryProfileUpsert"
            )
        case ("statsPreferences", "upsert"):
            route = .init(field: "statsPreferences", kind: "statsPreferencesUpsert")
        case ("terminalThemePreference", "delete"),
             ("terminalAccessoryProfile", "delete"),
             ("statsPreferences", "delete"):
            return .failure(.unsupportedOperation)
        default:
            return nil
        }

        let presentPayloadFields = LegacyUnionRoute.payloadFields.filter {
            guard let value = record[$0] else { return false }
            return !(value is NSNull)
        }
        guard presentPayloadFields.count == 1,
              presentPayloadFields.first == route.field,
              let value = record[route.field],
              let valueData = encodedJSONValue(value) else {
            return .failure(.missingOrConflictingPayload)
        }

        do {
            guard let payload = try decodeFeaturePayload(
                kind: route.kind,
                encodedValue: valueData
            ) else {
                return .failure(.unreadableLegacyRecord)
            }
            guard payload.entityKey == entityKey else {
                return .failure(.mismatchedEntityKey)
            }
            return .success(metadata.mutation(payload: payload))
        } catch {
            return .failure(.unreadableLegacyRecord)
        }
    }

    private func decodeFeaturePayload(
        kind: String,
        encodedValue: Data
    ) throws -> PendingCloudKitMutationPayload? {
        if let payload = try ServerPendingCloudKitPayloadCodec.migrateLegacy(
            kind: kind,
            encodedValue: encodedValue
        ) {
            return payload
        }
        if let payload = try TerminalThemePendingCloudKitPayloadCodec.migrateLegacy(
            kind: kind,
            encodedValue: encodedValue
        ) {
            return payload
        }
        if let payload = try TerminalAccessoryPendingCloudKitPayloadCodec.migrateLegacy(
            kind: kind,
            encodedValue: encodedValue
        ) {
            return payload
        }
        return try StatsPreferencesPendingCloudKitPayloadCodec.migrateLegacy(
            kind: kind,
            encodedValue: encodedValue
        )
    }

    private func encodedJSONValue(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}

nonisolated private struct LegacyMetadata: Decodable, Sendable {
    let id: UUID
    let createdAt: Date
    let retryCount: Int
    let nextRetryAt: Date?
    let lastErrorCode: String?
    let lastErrorDescription: String?

    func mutation(payload: PendingCloudKitMutationPayload) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: id,
            payload: payload,
            createdAt: createdAt,
            retryCount: retryCount,
            nextRetryAt: nextRetryAt,
            lastErrorCode: lastErrorCode,
            lastErrorDescription: lastErrorDescription
        )
    }
}

nonisolated private struct LegacyUnionRoute: Sendable {
    static let payloadFields = [
        "server",
        "workspace",
        "terminalTheme",
        "terminalThemePreference",
        "terminalAccessoryProfile",
        "statsPreferences"
    ]

    let field: String
    let kind: String
}
