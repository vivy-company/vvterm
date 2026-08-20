import CloudKit
import Foundation
import Testing
@testable import VVTerm

private enum TerminalThemeRecordTransportTestError: Error, Equatable {
    case missing
    case conflict
    case failed
}

@MainActor
private final class TerminalThemeRecordTransportStub: CloudKitRecordTransport {
    let cloudKitRecordZoneID = CKRecordZone.ID(
        zoneName: "TerminalThemeClientTests",
        ownerName: CKCurrentUserDefaultName
    )

    var listedRecords: Result<[CKRecord], Error> = .success([])
    var fetchedRecord: Result<CKRecord, Error> = .failure(
        TerminalThemeRecordTransportTestError.missing
    )
    var upsertResults: [Result<Void, Error>] = []
    private(set) var mutationCount = 0
    private(set) var requestedRecordTypes: Set<String>?
    private(set) var requestedKeys: [String]?
    private(set) var requestedRecordIDs: [CKRecord.ID] = []
    private(set) var upsertedRecords: [CKRecord] = []

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        mutationCount += 1
        return try await operation()
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        requestedRecordTypes = recordTypes
        requestedKeys = desiredKeys
        return try listedRecords.get()
    }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        requestedRecordIDs.append(recordID)
        return try fetchedRecord.get()
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {
        upsertedRecords.append(record)
        guard !upsertResults.isEmpty else { return }
        try upsertResults.removeFirst().get()
    }

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {}

    func cloudKitServerRecord(from error: Error) -> CKRecord? { nil }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        error as? TerminalThemeRecordTransportTestError == .missing
    }
}

@MainActor
struct TerminalThemeCloudKitClientTests {
    @Test
    func testFetchThemesRequestsCodecFieldsAndPreservesDeletedThemes() async throws {
        let active = makeTheme(id: UUID(), name: "Active", time: 10)
        let deleted = makeTheme(id: UUID(), name: "Deleted", time: 20, deletedAt: 20)
        let invalid = CKRecord(
            recordType: TerminalThemeCloudKitRecordCodec.recordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString)
        )
        invalid["name"] = "Invalid"
        let transport = TerminalThemeRecordTransportStub()
        transport.listedRecords = .success([
            TerminalThemeCloudKitRecordCodec.record(
                for: active,
                in: transport.cloudKitRecordZoneID
            ),
            TerminalThemeCloudKitRecordCodec.record(
                for: deleted,
                in: transport.cloudKitRecordZoneID
            ),
            invalid
        ])
        let client = TerminalThemeCloudKitClient(transport: transport)

        let themes = try await client.fetchTerminalThemes()

        #expect(themes == [active, deleted])
        #expect(transport.requestedRecordTypes == [TerminalThemeCloudKitRecordCodec.recordType])
        #expect(transport.requestedKeys == TerminalThemeCloudKitRecordCodec.recordKeys)
        #expect(transport.mutationCount == 0)
    }

    @Test
    func testMissingPreferenceReturnsNilWithStableRecordIdentity() async throws {
        let transport = TerminalThemeRecordTransportStub()
        let client = TerminalThemeCloudKitClient(transport: transport)

        let preference = try await client.fetchTerminalThemePreference()

        #expect(preference == nil)
        #expect(transport.requestedRecordIDs.count == 1)
        #expect(
            transport.requestedRecordIDs[0].recordName
                == TerminalThemePreferenceCloudKitRecordCodec.recordName
        )
        #expect(transport.requestedRecordIDs[0].zoneID == transport.cloudKitRecordZoneID)
    }

    @Test
    func testInvalidPreferenceIsIgnored() async throws {
        let invalid = CKRecord(
            recordType: TerminalThemePreferenceCloudKitRecordCodec.recordType,
            recordID: TerminalThemePreferenceCloudKitRecordCodec.recordID(
                in: CKRecordZone.ID(zoneName: "TerminalThemeClientTests")
            )
        )
        invalid["darkThemeName"] = "../Invalid"
        invalid["lightThemeName"] = "Aizen Light"
        invalid["usePerAppearanceTheme"] = 1
        let transport = TerminalThemeRecordTransportStub()
        transport.fetchedRecord = .success(invalid)
        let client = TerminalThemeCloudKitClient(transport: transport)

        let preference = try await client.fetchTerminalThemePreference()

        #expect(preference == nil)
    }

    @Test
    func testSaveThemeUsesOneUpsertAndPreservesTombstone() async throws {
        let theme = makeTheme(id: UUID(), name: "Deleted", time: 20, deletedAt: 20)
        let transport = TerminalThemeRecordTransportStub()
        let client = TerminalThemeCloudKitClient(transport: transport)

        try await client.saveTerminalTheme(theme)

        #expect(transport.mutationCount == 1)
        #expect(transport.upsertedRecords.count == 1)
        #expect(
            TerminalThemeCloudKitRecordCodec.theme(from: transport.upsertedRecords[0])
                == theme
        )
    }

    @Test
    func testServerConflictIsPropagatedWithoutSemanticRetry() async {
        let transport = TerminalThemeRecordTransportStub()
        transport.upsertResults = [
            .failure(TerminalThemeRecordTransportTestError.conflict)
        ]
        let client = TerminalThemeCloudKitClient(transport: transport)

        do {
            try await client.saveTerminalTheme(
                makeTheme(id: UUID(), name: "Conflict", time: 20)
            )
            Issue.record("Expected server conflict")
        } catch {
            #expect(error as? TerminalThemeRecordTransportTestError == .conflict)
        }

        #expect(transport.mutationCount == 1)
        #expect(transport.upsertedRecords.count == 1)
    }

    @Test
    func testSavePreferenceUsesStableRecordIdentity() async throws {
        let preference = makePreference(time: 30)
        let transport = TerminalThemeRecordTransportStub()
        let client = TerminalThemeCloudKitClient(transport: transport)

        try await client.saveTerminalThemePreference(preference)

        #expect(transport.mutationCount == 1)
        #expect(transport.upsertedRecords.count == 1)
        let record = transport.upsertedRecords[0]
        #expect(
            record.recordID.recordName
                == TerminalThemePreferenceCloudKitRecordCodec.recordName
        )
        #expect(record.recordID.zoneID == transport.cloudKitRecordZoneID)
        #expect(TerminalThemePreferenceCloudKitRecordCodec.preference(from: record) == preference)
    }

    private func makeTheme(
        id: UUID,
        name: String,
        time: TimeInterval,
        deletedAt: TimeInterval? = nil
    ) -> TerminalTheme {
        TerminalTheme(
            id: id,
            name: name,
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSince1970: time),
            deletedAt: deletedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func makePreference(time: TimeInterval) -> TerminalThemePreference {
        TerminalThemePreference(
            darkThemeName: "Aizen Dark",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true,
            updatedAt: Date(timeIntervalSince1970: time)
        )
    }
}
