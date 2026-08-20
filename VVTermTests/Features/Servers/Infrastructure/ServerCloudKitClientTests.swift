import CloudKit
import Foundation
import Testing
@testable import VVTerm

private enum ServerCloudKitTransportTestError: Error, Equatable {
    case failed
}

@MainActor
private final class ServerCloudKitRecordTransportStub: CloudKitRecordChangeTransport {
    let cloudKitRecordZoneID = CKRecordZone.ID(
        zoneName: "ServerCloudKitClientTests",
        ownerName: CKCurrentUserDefaultName
    )
    var isCloudKitAvailable = true
    var cloudKitSyncGeneration = UUID()
    var changesResult: Result<CloudKitRawRecordChanges, Error> = .success(
        CloudKitRawRecordChanges(
            changes: [],
            isFullFetch: false,
            checkpoint: CloudKitRecordChangeCheckpoint(id: UUID())
        )
    )
    var upsertResult: Result<Void, Error> = .success(())
    var deleteResult: Result<Void, Error> = .success(())
    private(set) var fetchRequests: [(forceFullFetch: Bool, desiredKeys: [String])] = []
    private(set) var mutationCount = 0
    private(set) var upsertedRecords: [CKRecord] = []
    private(set) var deletedRecordIDs: [CKRecord.ID] = []
    private(set) var committedCheckpoints: [CloudKitRecordChangeCheckpoint] = []

    func fetchCloudKitRecordChanges(
        forceFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges {
        fetchRequests.append((forceFullFetch, desiredKeys))
        return try changesResult.get()
    }

    func commitCloudKitRecordChanges(
        _ checkpoint: CloudKitRecordChangeCheckpoint
    ) throws {
        committedCheckpoints.append(checkpoint)
    }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        mutationCount += 1
        return try await operation()
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] { [] }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        CKRecord(recordType: "Unused", recordID: recordID)
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {
        upsertedRecords.append(record)
        try upsertResult.get()
    }

    func deleteCloudKitRecord(_ recordID: CKRecord.ID) async throws {
        deletedRecordIDs.append(recordID)
        try deleteResult.get()
    }

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {}

    func cloudKitServerRecord(from error: Error) -> CKRecord? { nil }
    func isCloudKitRecordMissing(_ error: Error) -> Bool { false }
}

@MainActor
struct ServerCloudKitClientTests {
    @Test
    func rawChangesDecodeAndDedupeWithLastEventWinning() async throws {
        let transport = ServerCloudKitRecordTransportStub()
        let fallbackDate = Date(timeIntervalSinceReferenceDate: 9_000)
        let workspace = makeWorkspace(id: UUID(), name: "Initial Workspace")
        var updatedWorkspace = workspace
        updatedWorkspace.name = "Updated Workspace"
        let server = makeServer(id: UUID(), workspaceID: workspace.id, name: "Initial Server")
        var updatedServer = server
        updatedServer.name = "Updated Server"
        let deletedServerID = UUID()
        let deletedWorkspaceID = UUID()
        transport.changesResult = .success(
            CloudKitRawRecordChanges(
                changes: [
                    .record(serverRecord(server, transport: transport, now: fallbackDate)),
                    .deletion(
                        recordID: recordID(server.id, transport: transport),
                        recordType: ServerCloudKitRecordCodec.recordType
                    ),
                    .record(serverRecord(updatedServer, transport: transport, now: fallbackDate)),
                    .record(workspaceRecord(workspace, transport: transport, now: fallbackDate)),
                    .record(workspaceRecord(updatedWorkspace, transport: transport, now: fallbackDate)),
                    .deletion(
                        recordID: recordID(deletedServerID, transport: transport),
                        recordType: ServerCloudKitRecordCodec.recordType
                    ),
                    .deletion(
                        recordID: recordID(deletedWorkspaceID, transport: transport),
                        recordType: WorkspaceCloudKitRecordCodec.recordType
                    )
                ],
                isFullFetch: true,
                checkpoint: CloudKitRecordChangeCheckpoint(id: UUID())
            )
        )
        let client = ServerCloudKitClient(transport: transport, now: { fallbackDate })

        let changes = try await client.fetchServerChanges(forceFullFetch: true)

        #expect(changes.servers.map(\.name) == ["Updated Server"])
        #expect(changes.workspaces.map(\.name) == ["Updated Workspace"])
        #expect(Set(changes.deletedServerIDs) == [deletedServerID])
        #expect(Set(changes.deletedWorkspaceIDs) == [deletedWorkspaceID])
        #expect(changes.isFullFetch)
        let checkpoint = changes.checkpoint
        try client.acceptServerChanges(checkpoint)
        #expect(transport.committedCheckpoints.map(\.id) == [checkpoint.id])
        #expect(transport.fetchRequests.map(\.forceFullFetch) == [true])
        #expect(
            Set(transport.fetchRequests[0].desiredKeys)
                == Set(
                    ServerCloudKitRecordCodec.recordKeys
                        + WorkspaceCloudKitRecordCodec.recordKeys
                )
        )
    }

    @Test
    func malformedKnownRecordFailsTheCompleteBatch() async {
        let transport = ServerCloudKitRecordTransportStub()
        let invalidServer = CKRecord(
            recordType: ServerCloudKitRecordCodec.recordType,
            recordID: recordID(UUID(), transport: transport)
        )
        invalidServer["name"] = "Missing Required Fields"
        transport.changesResult = .success(
            CloudKitRawRecordChanges(
                changes: [
                    .record(invalidServer),
                    .deletion(
                        recordID: CKRecord.ID(
                            recordName: "not-a-uuid",
                            zoneID: transport.cloudKitRecordZoneID
                        ),
                        recordType: ServerCloudKitRecordCodec.recordType
                    ),
                    .record(
                        CKRecord(
                            recordType: "Unrelated",
                            recordID: recordID(UUID(), transport: transport)
                        )
                    )
                ],
                isFullFetch: false,
                checkpoint: CloudKitRecordChangeCheckpoint(id: UUID())
            )
        )
        let client = ServerCloudKitClient(transport: transport, now: Date.init)

        await #expect(throws: ServerCloudKitDecodingError.self) {
            try await client.fetchServerChanges(forceFullFetch: false)
        }
        #expect(transport.committedCheckpoints.isEmpty)
    }

    @Test
    func unknownRecordTypesRemainIgnorable() async throws {
        let transport = ServerCloudKitRecordTransportStub()
        transport.changesResult = .success(
            CloudKitRawRecordChanges(
                changes: [
                    .record(
                        CKRecord(
                            recordType: "Unrelated",
                            recordID: recordID(UUID(), transport: transport)
                        )
                    )
                ],
                isFullFetch: false,
                checkpoint: CloudKitRecordChangeCheckpoint(id: UUID())
            )
        )
        let client = ServerCloudKitClient(transport: transport, now: Date.init)

        let changes = try await client.fetchServerChanges(forceFullFetch: false)

        #expect(changes.servers.isEmpty)
        #expect(changes.workspaces.isEmpty)
    }

    @Test
    func saveAndDeletePreserveRecordIdentityAndUseInjectedClock() async throws {
        let transport = ServerCloudKitRecordTransportStub()
        let date = Date(timeIntervalSinceReferenceDate: 5_000)
        let workspace = makeWorkspace(id: UUID(), name: "Workspace")
        let server = makeServer(id: UUID(), workspaceID: workspace.id, name: "Server")
        let client = ServerCloudKitClient(transport: transport, now: { date })

        try await client.saveServer(server)
        try await client.saveWorkspace(workspace)
        try await client.deleteServer(server)
        try await client.deleteWorkspace(workspace)

        #expect(transport.mutationCount == 4)
        #expect(transport.upsertedRecords.count == 2)
        #expect(transport.upsertedRecords[0].recordID.recordName == server.id.uuidString)
        #expect(transport.upsertedRecords[0].recordID.zoneID == transport.cloudKitRecordZoneID)
        #expect(transport.upsertedRecords[0]["updatedAt"] as? Date == date)
        #expect(transport.upsertedRecords[1].recordID.recordName == workspace.id.uuidString)
        #expect(transport.upsertedRecords[1].recordID.zoneID == transport.cloudKitRecordZoneID)
        #expect(transport.upsertedRecords[1]["updatedAt"] as? Date == date)
        #expect(transport.deletedRecordIDs.map(\.recordName) == [
            server.id.uuidString,
            workspace.id.uuidString
        ])
        #expect(transport.deletedRecordIDs.allSatisfy {
            $0.zoneID == transport.cloudKitRecordZoneID
        })
    }

    @Test
    func mutationFailurePropagatesWithoutRetry() async {
        let transport = ServerCloudKitRecordTransportStub()
        transport.upsertResult = .failure(ServerCloudKitTransportTestError.failed)
        let workspace = makeWorkspace(id: UUID(), name: "Workspace")
        let server = makeServer(id: UUID(), workspaceID: workspace.id, name: "Server")
        let client = ServerCloudKitClient(transport: transport, now: Date.init)

        do {
            try await client.saveServer(server)
            Issue.record("Expected mutation failure")
        } catch {
            #expect(error as? ServerCloudKitTransportTestError == .failed)
        }

        #expect(transport.mutationCount == 1)
        #expect(transport.upsertedRecords.count == 1)
    }

    @Test
    func fetchFailurePropagatesAndAvailabilityForwards() async {
        let transport = ServerCloudKitRecordTransportStub()
        transport.isCloudKitAvailable = false
        transport.changesResult = .failure(ServerCloudKitTransportTestError.failed)
        let client = ServerCloudKitClient(transport: transport, now: Date.init)

        #expect(!client.isAvailable)
        do {
            _ = try await client.fetchServerChanges(forceFullFetch: true)
            Issue.record("Expected fetch failure")
        } catch {
            #expect(error as? ServerCloudKitTransportTestError == .failed)
        }
        #expect(transport.fetchRequests.map(\.forceFullFetch) == [true])
    }

    @Test
    func schemaClassificationPreservesCloudKitAndMessageRules() {
        #expect(ServerCloudKitClient.isSchemaError(CKError(.unknownItem)))
        #expect(ServerCloudKitClient.isSchemaError(CKError(.invalidArguments)))
        #expect(!ServerCloudKitClient.isSchemaError(CKError(.networkFailure)))
        #expect(ServerCloudKitClient.isSchemaError(TestMessageError("Unknown record type")))
        #expect(!ServerCloudKitClient.isSchemaError(TestMessageError("Network failed")))
    }

    private func serverRecord(
        _ server: Server,
        transport: ServerCloudKitRecordTransportStub,
        now: Date
    ) -> CKRecord {
        ServerCloudKitRecordCodec.record(
            for: server,
            in: transport.cloudKitRecordZoneID,
            now: now
        )
    }

    private func workspaceRecord(
        _ workspace: Workspace,
        transport: ServerCloudKitRecordTransportStub,
        now: Date
    ) -> CKRecord {
        WorkspaceCloudKitRecordCodec.record(
            for: workspace,
            in: transport.cloudKitRecordZoneID,
            now: now
        )
    }

    private func recordID(
        _ id: UUID,
        transport: ServerCloudKitRecordTransportStub
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: transport.cloudKitRecordZoneID)
    }

    private func makeServer(id: UUID, workspaceID: UUID, name: String) -> Server {
        Server(
            id: id,
            workspaceId: workspaceID,
            environment: .production,
            name: name,
            host: "server.example.test",
            port: 22,
            eternalTerminalPort: 2_022,
            username: "tester",
            connectionMode: .standard,
            authMethod: .password,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }

    private func makeWorkspace(id: UUID, name: String) -> Workspace {
        Workspace(
            id: id,
            name: name,
            colorHex: "#123456",
            order: 1,
            environments: ServerEnvironment.builtInEnvironments,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }
}

private struct TestMessageError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
