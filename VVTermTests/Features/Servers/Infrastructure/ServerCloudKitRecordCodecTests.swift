import CloudKit
import Foundation
import Testing
@testable import VVTerm

struct ServerCloudKitRecordCodecTests {
    @Test
    func serverRecordPreservesIdentityAndRoundTripsFields() throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: "test-owner")
        let server = makeServer()
        let now = Date(timeIntervalSinceReferenceDate: 3_000)

        let record = ServerCloudKitRecordCodec.record(
            for: server,
            in: zoneID,
            now: now
        )

        #expect(record.recordType == "Server")
        #expect(record.recordID.recordName == server.id.uuidString)
        #expect(record.recordID.zoneID == zoneID)
        var expected = server
        expected.updatedAt = now
        #expect(ServerCloudKitRecordCodec.server(from: record, now: now) == expected)
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
        let serverRecord = ServerCloudKitRecordCodec.record(
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
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.example.test",
            cloudflareAppDomainOverride: "app.example.test",
            tags: ["one", "two"],
            notes: "Notes",
            lastConnected: Date(timeIntervalSinceReferenceDate: 1_500),
            isFavorite: true,
            requiresBiometricUnlock: true,
            tmuxEnabledOverride: false,
            tmuxStartupBehaviorOverride: .skipTmux,
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
