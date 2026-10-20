import CloudKit
import Foundation
import Testing
@testable import VVTerm

struct ServerCloudKitRecordCodecTests {
    @Test
    func savedTeleportCloudSettingsAreReadAndClearedOnTheNextWrite() throws {
        let configuration = try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            clusterName: "root.example.test", nodeID: "node-id"
        )
        var server = makeServer()
        server.connectionMode = .teleport
        server.teleportConfiguration = configuration
        let zone = CKRecordZone.ID(zoneName: "test-zone")
        let record = try ServerCloudKitRecordCodec.record(for: server, in: zone, now: .distantPast)
        record["transportConfiguration"] = nil
        record["teleportConfiguration"] = try JSONEncoder().encode(configuration)
        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: .distantPast))
        #expect(decoded.teleportConfiguration == configuration)
        let saved = try ServerCloudKitRecordCodec.record(for: decoded, in: zone, now: .distantPast)
        #expect(saved["transportConfiguration"] is Data)
        #expect(saved["teleportConfiguration"] == nil)
        #expect(saved.changedKeys().contains("teleportConfiguration"))
        #expect(ServerCloudKitRecordCodec.recordKeys.contains("teleportConfiguration"))

        record["transportConfiguration"] = Data("{}".utf8)
        #expect(ServerCloudKitRecordCodec.server(from: record, now: .distantPast) == nil)
        let future = ServerTransportConfiguration.unsupported(
            type: "teleport", version: 2, settings: Data([0, 255])
        )
        record["transportConfiguration"] = try JSONEncoder().encode(future)
        let unsupported = try #require(ServerCloudKitRecordCodec.server(from: record, now: .distantPast))
        #expect(unsupported.transportConfiguration == future)
        #expect(unsupported.teleportConfiguration == nil)
        #expect(!unsupported.isTransportSupported)
    }

    @Test(arguments: [false, true])
    func legacyCloudSettingsMustBeValidAndBounded(isOversized: Bool) throws {
        let server = makeServer()
        let record = try ServerCloudKitRecordCodec.record(
            for: server, in: CKRecordZone.ID(zoneName: "test-zone"), now: .distantPast
        )
        record["connectionMode"] = SSHConnectionMode.teleport.rawValue
        record["transportConfiguration"] = nil
        record["teleportConfiguration"] = isOversized
            ? Data(repeating: 32, count: ServerTransportConfiguration.maximumSettingsSize + 1)
            : Data("{}".utf8)
        #expect(ServerCloudKitRecordCodec.server(from: record, now: .distantPast) == nil)
    }

    @Test
    func transportChangeClearsTheCloudFieldWithChangedKeys() throws {
        var server = makeServer()
        server.connectionMode = .teleport
        server.teleportConfiguration = try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            clusterName: "root.example.test", nodeID: "node-id"
        )
        server.connectionMode = .standard
        let record = try ServerCloudKitRecordCodec.record(
            for: server, in: CKRecordZone.ID(zoneName: "test-zone"), now: .distantPast
        )
        #expect(record["transportConfiguration"] == nil)
        #expect(record.changedKeys().contains("transportConfiguration"))
    }

    @Test
    func oversizedCloudPayloadIsRejectedBeforeDecoding() throws {
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(), in: CKRecordZone.ID(zoneName: "test-zone"), now: .distantPast
        )
        record["transportConfiguration"] = Data(
            repeating: 32, count: ServerTransportConfiguration.maximumEncodedSize + 1
        )
        #expect(ServerCloudKitRecordCodec.server(from: record, now: .distantPast) == nil)
    }

    @Test
    func invalidCloudTransportTypeCannotBecomeOrdinarySSH() throws {
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(), in: CKRecordZone.ID(zoneName: "test-zone"), now: .distantPast
        )
        record["connectionMode"] = 1
        #expect(ServerCloudKitRecordCodec.server(from: record, now: .distantPast) == nil)
    }

    @Test
    func teleportCloudRecordSyncsMetadataAndDoesNotRequireAnSSHAuthMethod() throws {
        let configuration = try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            clusterName: "root.example.test", nodeID: "node-id"
        )
        let server = Server(
            workspaceId: UUID(), name: "Teleport", host: configuration.nodeID,
            username: "deploy", connectionMode: .teleport,
            teleportConfiguration: configuration
        )
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = try ServerCloudKitRecordCodec.record(
            for: server, in: CKRecordZone.ID(zoneName: "test-zone"), now: now
        )
        #expect(record["authMethod"] == nil)
        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))
        #expect(decoded.teleportConfiguration == configuration)
        #expect(decoded.authMethod == nil)
        #expect(decoded.username == "deploy")
        let metadata = try #require(record["transportConfiguration"] as? Data)
        let payload = try JSONDecoder().decode(ServerTransportConfiguration.self, from: metadata)
        #expect(payload == .teleport(configuration))
        #expect(record["teleportConfiguration"] == nil)
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(configuration)
        ) as? [String: Any])
        #expect(Set(object.keys) == ["profile", "clusterName", "nodeID"])
        let profile = try #require(object["profile"] as? [String: Any])
        #expect(Set(profile.keys) == ["proxyURL", "account"])
        record["transportConfiguration"] = nil
        #expect(ServerCloudKitRecordCodec.server(from: record, now: now) == nil)
    }

    @Test
    func serverRecordPreservesIdentityAndRoundTripsFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let server = makeServer()
        let now = Date(timeIntervalSinceReferenceDate: 3_000)

        let record = try ServerCloudKitRecordCodec.record(
            for: server,
            in: zoneID,
            now: now
        )

        #expect(record.recordType == "Server")
        #expect(record.recordID.recordName == server.id.uuidString)
        #expect(record.recordID.zoneID == zoneID)
        #expect(record["remoteSessionBackendIdentifier"] as? String == "zmx")
        #expect(record["iconSelection"] as? String == "custom:database")
        #expect(record["detectedSystemKind"] as? String == "macos")
        #expect(record["appleHardwareModelIdentifier"] as? String == "MacBookPro18,3")
        #expect(record["tmuxEnabledOverride"] as? Bool == false)
        #expect(record["tmuxStartupBehaviorOverride"] as? String == "skipTmux")
        #expect(
            record["remoteShellStartupCommand"] as? String
                == "cd /srv/round-trip && exec $SHELL -l"
        )
        var expected = server
        expected.updatedAt = now
        #expect(ServerCloudKitRecordCodec.server(from: record, now: now) == expected)
    }

    @Test
    func legacyCloudRecordDefaultsToAutomaticWithoutDetection() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(),
            in: zoneID,
            now: now
        )
        record["iconSelection"] = nil
        record["detectedSystemKind"] = nil
        record["detectedSystemDisplayName"] = nil
        record["appleHardwareModelIdentifier"] = nil

        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(decoded.iconSelection == .automatic)
        #expect(decoded.detectedSystemIdentity == nil)
    }

    @Test(arguments: [
        (RemoteSessionStartupBehavior.createManaged, "vvtermManaged"),
        (RemoteSessionStartupBehavior.ask, "askEveryTime"),
        (RemoteSessionStartupBehavior.plainShell, "skipTmux")
    ])
    func currentTmuxSettingsUpdateTheirLegacyCloudKitProjection(
        behavior: RemoteSessionStartupBehavior,
        legacyRawValue: String
    ) throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        var server = makeServer()
        server.remoteSessionEnabledOverride = true
        server.remoteSessionBackendIdentifier = .tmux
        server.remoteSessionStartupBehaviorOverride = behavior

        let record = try ServerCloudKitRecordCodec.record(
            for: server,
            in: zoneID,
            now: Date(timeIntervalSinceReferenceDate: 3_000)
        )

        #expect(record["tmuxEnabledOverride"] as? Bool == true)
        #expect(record["tmuxStartupBehaviorOverride"] as? String == legacyRawValue)
    }

    @Test
    func legacyTmuxRecordMigratesToCurrentRemoteSessionFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(),
            in: zoneID,
            now: now
        )
        record["remoteSessionEnabledOverride"] = nil
        record["remoteSessionBackendIdentifier"] = nil
        record["remoteSessionStartupBehaviorOverride"] = nil
        record["tmuxEnabledOverride"] = true
        record["tmuxStartupBehaviorOverride"] = "vvtermManaged"

        let migrated = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(migrated.remoteSessionEnabledOverride == true)
        #expect(migrated.remoteSessionBackendIdentifier == .tmux)
        #expect(migrated.remoteSessionStartupBehaviorOverride == .createManaged)
    }

    @Test
    func legacyTmuxChangesOverrideStaleCurrentTmuxFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        var server = makeServer()
        server.remoteSessionBackendIdentifier = .tmux
        server.remoteSessionEnabledOverride = true
        server.remoteSessionStartupBehaviorOverride = .createManaged
        let record = try ServerCloudKitRecordCodec.record(for: server, in: zoneID, now: now)
        record["tmuxEnabledOverride"] = false
        record["tmuxStartupBehaviorOverride"] = "askEveryTime"

        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(decoded.remoteSessionEnabledOverride == false)
        #expect(decoded.remoteSessionStartupBehaviorOverride == .ask)
    }

    @Test
    func legacyTmuxProjectionDoesNotOverrideAnotherBackend() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        var server = makeServer()
        server.remoteSessionBackendIdentifier = .zmx
        server.remoteSessionEnabledOverride = true
        server.remoteSessionStartupBehaviorOverride = .ask
        let record = try ServerCloudKitRecordCodec.record(for: server, in: zoneID, now: now)
        record["tmuxEnabledOverride"] = false
        record["tmuxStartupBehaviorOverride"] = "skipTmux"

        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(decoded.remoteSessionEnabledOverride == true)
        #expect(decoded.remoteSessionStartupBehaviorOverride == .ask)
    }

    @Test
    func invalidSyncedStartupCommandIsIgnored() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(),
            in: zoneID,
            now: now
        )
        record["remoteShellStartupCommand"] = String(
            repeating: "x",
            count: RemoteShellStartupAction.maximumCommandByteCount + 1
        )

        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(decoded.remoteShellStartupAction == nil)
    }

    @Test
    func invalidSyncedWakeConfigurationIsIgnored() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(),
            in: zoneID,
            now: now
        )
        record["wakeOnLANConfiguration"] = Data("invalid".utf8)

        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(decoded.wakeOnLANConfiguration == nil)
    }

    @Test
    func missingAutomaticWakeFieldDefaultsToOff() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = try ServerCloudKitRecordCodec.record(
            for: makeServer(),
            in: zoneID,
            now: now
        )
        record["autoWakeOnLANEnabled"] = nil

        let decoded = try #require(ServerCloudKitRecordCodec.server(from: record, now: now))

        #expect(!decoded.autoWakeOnLANEnabled)
    }

    @Test
    func workspaceRecordPreservesIdentityAndRoundTripsFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let workspace = makeWorkspace()
        let now = Date(timeIntervalSinceReferenceDate: 3_000)

        let record = WorkspaceCloudKitRecordCodec.record(
            for: workspace,
            in: zoneID,
            now: now
        )

        #expect(record.recordType == "Workspace")
        #expect(record.recordID.recordName == workspace.id.uuidString)
        #expect(record.recordID.zoneID == zoneID)
        var expected = workspace
        expected.updatedAt = now
        #expect(WorkspaceCloudKitRecordCodec.workspace(from: record, now: now) == expected)
    }

    @Test
    func missingRecordDatesUseOneExplicitFallbackClock() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let fallback = Date(timeIntervalSinceReferenceDate: 4_000)
        let serverRecord = try ServerCloudKitRecordCodec.record(
            for: makeServer(),
            in: zoneID,
            now: fallback
        )
        serverRecord["createdAt"] = nil
        serverRecord["updatedAt"] = nil
        let workspaceRecord = WorkspaceCloudKitRecordCodec.record(
            for: makeWorkspace(),
            in: zoneID,
            now: fallback
        )
        workspaceRecord["createdAt"] = nil
        workspaceRecord["updatedAt"] = nil

        let server = try #require(
            ServerCloudKitRecordCodec.server(from: serverRecord, now: fallback)
        )
        let workspace = try #require(
            WorkspaceCloudKitRecordCodec.workspace(from: workspaceRecord, now: fallback)
        )

        #expect(server.createdAt == fallback)
        #expect(server.updatedAt == fallback)
        #expect(workspace.createdAt == fallback)
        #expect(workspace.updatedAt == fallback)
    }

    @Test
    func domainCodableShapeRoundTripsWithoutLosingValues() throws {
        let server = makeServer()
        let workspace = makeWorkspace()

        let serverData = try JSONEncoder().encode(server)
        let workspaceData = try JSONEncoder().encode(workspace)

        #expect(try JSONDecoder().decode(Server.self, from: serverData) == server)
        #expect(try JSONDecoder().decode(Workspace.self, from: workspaceData) == workspace)
    }

    private func makeServer() -> Server {
        Server(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            workspaceId: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            environment: ServerEnvironment(
                id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                name: "QA",
                shortName: "QA",
                colorHex: "#123456"
            ),
            name: "Round Trip",
            host: "roundtrip.example.test",
            port: 2_222,
            eternalTerminalPort: 2_023,
            username: "tester",
            connectionMode: .cloudflare,
            authMethod: .sshKeyWithPassphrase,
            iconSelection: .custom(.database),
            detectedSystemIdentity: RemoteSystemIdentity(
                kind: .macOS,
                displayName: "macOS",
                appleHardwareModelIdentifier: AppleHardwareModelIdentifier(
                    rawValue: "MacBookPro18,3"
                )!
            ),
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.example.test",
            cloudflareAppDomainOverride: "app.example.test",
            wakeOnLANConfiguration: WakeOnLANConfiguration(
                macAddress: try! WakeOnLANMACAddress("00:11:22:33:44:55")
            ),
            autoWakeOnLANEnabled: true,
            tags: ["one", "two"],
            notes: "Notes",
            lastConnected: Date(timeIntervalSinceReferenceDate: 1_500),
            isFavorite: true,
            requiresBiometricUnlock: true,
            remoteSessionEnabledOverride: false,
            remoteSessionBackendIdentifier: .zmx,
            remoteSessionStartupBehaviorOverride: .plainShell,
            remoteShellStartupCommand: "cd /srv/round-trip && exec $SHELL -l",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }

    private func makeWorkspace() -> Workspace {
        let environment = ServerEnvironment(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Preview",
            shortName: "Pre",
            colorHex: "#654321"
        )
        return Workspace(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Round Trip",
            colorHex: "#ABCDEF",
            icon: "terminal",
            order: 7,
            environments: [environment],
            lastSelectedEnvironmentId: environment.id,
            lastSelectedServerId: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }
}
