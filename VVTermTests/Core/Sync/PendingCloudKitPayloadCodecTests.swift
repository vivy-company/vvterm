import Foundation
import Testing
@testable import VVTerm

@MainActor
struct PendingCloudKitPayloadCodecTests {
    @Test
    func serverCodecOwnsKeysOperationsAndDrainOrder() throws {
        let workspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Workspace"
        )
        let server = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspace.id,
            name: "Server",
            host: "example.test",
            username: "tester"
        )
        let payloads = try [
            ServerPendingCloudKitPayloadCodec.encode(.workspaceUpsert(workspace)),
            ServerPendingCloudKitPayloadCodec.encode(.serverUpsert(server)),
            ServerPendingCloudKitPayloadCodec.encode(.serverDelete(server)),
            ServerPendingCloudKitPayloadCodec.encode(.workspaceDelete(workspace))
        ]

        #expect(payloads.map(\.entityType) == ["workspace", "server", "server", "workspace"])
        #expect(payloads.map(\.entityKey) == [
            workspace.id.uuidString,
            server.id.uuidString,
            server.id.uuidString,
            workspace.id.uuidString
        ])
        #expect(payloads.map(\.operation) == [.upsert, .upsert, .delete, .delete])
        #expect(payloads.map(\.drainPriority) == [0, 1, 6, 7])
        #expect(payloads.map(\.isDelete) == [false, false, true, true])

        let decoded = try payloads.compactMap(ServerPendingCloudKitPayloadCodec.decode)
        #expect(decoded == [
            .workspaceUpsert(workspace),
            .serverUpsert(server),
            .serverDelete(server),
            .workspaceDelete(workspace)
        ])
    }

    @Test
    func codecsRejectRoutingMetadataThatDoesNotMatchDecodedValue() throws {
        let workspace = Workspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000011")!,
            name: "Workspace"
        )
        let server = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!,
            workspaceId: workspace.id,
            name: "Server",
            host: "example.test",
            username: "tester"
        )
        let wrongKey = try PendingCloudKitPayloadEnvelope(
            entityType: ServerPendingCloudKitPayloadCodec.serverEntityType,
            entityKey: workspace.id.uuidString,
            operation: .upsert,
            drainPriority: 1,
            value: server
        )
        let wrongPriority = try PendingCloudKitPayloadEnvelope(
            entityType: ServerPendingCloudKitPayloadCodec.serverEntityType,
            entityKey: server.id.uuidString,
            operation: .upsert,
            drainPriority: 0,
            value: server
        )

        #expect(throws: PendingCloudKitPayloadEnvelopeError.self) {
            try ServerPendingCloudKitPayloadCodec.decode(wrongKey)
        }
        #expect(throws: PendingCloudKitPayloadEnvelopeError.self) {
            try ServerPendingCloudKitPayloadCodec.decode(wrongPriority)
        }
        #expect(!ServerPendingCloudKitPayloadCodec.contains(wrongKey))
        #expect(!ServerPendingCloudKitPayloadCodec.contains(wrongPriority))
    }

    @Test
    func themeCodecRoundTripsThemeAndPreference() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let theme = TerminalTheme(
            name: "Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: updatedAt
        )
        let preference = TerminalThemePreference(
            darkThemeName: theme.name,
            lightThemeName: theme.name,
            usePerAppearanceTheme: false,
            updatedAt: updatedAt
        )
        let themePayload = try TerminalThemePendingCloudKitPayloadCodec.encodeTheme(theme)
        let preferencePayload = try TerminalThemePendingCloudKitPayloadCodec.encodePreference(
            preference
        )

        #expect(themePayload.coalescingKey == "terminalTheme:\(theme.id.uuidString)")
        #expect(themePayload.drainPriority == 2)
        #expect(
            preferencePayload.coalescingKey
                == "terminalThemePreference:\(TerminalThemePreference.recordName)"
        )
        #expect(preferencePayload.drainPriority == 3)
        let decodedTheme = try TerminalThemePendingCloudKitPayloadCodec.decodeTheme(themePayload)
        let decodedPreference = try TerminalThemePendingCloudKitPayloadCodec.decodePreference(
            preferencePayload
        )
        #expect(decodedTheme == theme)
        #expect(decodedPreference == preference)
    }

    @Test
    func accessoryAndStatsCodecsRoundTripFeatureValues() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let profile = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: [],
                updatedAt: updatedAt
            ),
            customActions: [],
            updatedAt: updatedAt,
            lastWriterDeviceId: "test-device"
        )
        let preferences = StatsPreferences(
            style: .classic,
            blocks: [],
            updatedAt: updatedAt,
            lastWriterDeviceId: "test-device"
        )
        let profilePayload = try TerminalAccessoryPendingCloudKitPayloadCodec.encode(profile)
        let preferencesPayload = try StatsPreferencesPendingCloudKitPayloadCodec.encode(preferences)

        #expect(profilePayload.drainPriority == 4)
        #expect(preferencesPayload.drainPriority == 5)
        let decodedProfile = try TerminalAccessoryPendingCloudKitPayloadCodec.decode(profilePayload)
        let decodedPreferences = try StatsPreferencesPendingCloudKitPayloadCodec.decode(
            preferencesPayload
        )
        #expect(decodedProfile == profile)
        #expect(decodedPreferences == preferences)
    }
}
