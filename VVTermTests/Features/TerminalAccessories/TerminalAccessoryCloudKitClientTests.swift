import CloudKit
import Foundation
import Testing
@testable import VVTerm

private enum TerminalAccessoryRecordTransportTestError: Error, Equatable {
    case missing
    case conflict
    case failed
}

@MainActor
private final class TerminalAccessoryRecordTransportStub: CloudKitRecordTransport {
    let cloudKitRecordZoneID = CKRecordZone.ID(
        zoneName: "TerminalAccessoryClientTests",
        ownerName: CKCurrentUserDefaultName
    )

    var fetchResult: Result<CKRecord, Error>
    var saveResults: [Result<Void, Error>] = []
    var conflictRecord: CKRecord?
    private(set) var mutationCount = 0
    private(set) var savedRecords: [CKRecord] = []

    init(fetchResult: Result<CKRecord, Error>) {
        self.fetchResult = fetchResult
    }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        mutationCount += 1
        return try await operation()
    }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        try fetchResult.get()
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        []
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {}

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {
        savedRecords.append(record)
        guard !saveResults.isEmpty else { return }
        try saveResults.removeFirst().get()
    }

    func cloudKitServerRecord(from error: Error) -> CKRecord? {
        guard error as? TerminalAccessoryRecordTransportTestError == .conflict else {
            return nil
        }
        return conflictRecord
    }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        error as? TerminalAccessoryRecordTransportTestError == .missing
    }
}

@MainActor
private final class TerminalAccessoryCloudClientSpy: TerminalAccessoryCloudClient {
    let resolvedProfile: TerminalAccessoryProfile
    private(set) var receivedProfiles: [TerminalAccessoryProfile] = []

    init(resolvedProfile: TerminalAccessoryProfile) {
        self.resolvedProfile = resolvedProfile
    }

    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        receivedProfiles.append(localProfile)
        return resolvedProfile
    }
}

@MainActor
private final class TerminalAccessoryResolutionPublisherSpy:
    TerminalAccessoryResolutionPublishing {
    private(set) var profiles: [TerminalAccessoryProfile] = []

    func publishTerminalAccessoryProfile(_ profile: TerminalAccessoryProfile) {
        profiles.append(profile)
    }
}

@MainActor
struct TerminalAccessoryCloudKitClientTests {
    @Test
    func testRemoteWinnerCompletesWithoutWriting() async throws {
        let local = makeProfile(time: 10, writer: "local")
        let remote = makeProfile(time: 20, writer: "remote")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .success(try record(for: remote))
        )
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        let resolved = try await client.syncTerminalAccessoryProfile(local)

        #expect(resolved == remote.normalized())
        #expect(transport.mutationCount == 1)
        #expect(transport.savedRecords.isEmpty)
    }

    @Test
    func testServerConflictMergesAndRetriesAgainstServerRecord() async throws {
        let local = makeProfile(time: 30, writer: "local")
        let initialRemote = makeProfile(time: 10, writer: "initial")
        let conflictRemote = makeProfile(time: 20, writer: "conflict")
        let conflictRecord = try record(for: conflictRemote)
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .success(try record(for: initialRemote))
        )
        transport.conflictRecord = conflictRecord
        transport.saveResults = [
            .failure(TerminalAccessoryRecordTransportTestError.conflict),
            .success(())
        ]
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        let resolved = try await client.syncTerminalAccessoryProfile(local)

        #expect(resolved == local.normalized())
        #expect(transport.savedRecords.count == 2)
        #expect(transport.savedRecords[1] === conflictRecord)
    }

    @Test
    func testServerConflictReturnsNewerRemoteWithoutAnotherWrite() async throws {
        let local = makeProfile(time: 20, writer: "local")
        let initialRemote = makeProfile(time: 10, writer: "initial")
        let conflictRemote = makeProfile(time: 30, writer: "conflict")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .success(try record(for: initialRemote))
        )
        transport.conflictRecord = try record(for: conflictRemote)
        transport.saveResults = [
            .failure(TerminalAccessoryRecordTransportTestError.conflict)
        ]
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        let resolved = try await client.syncTerminalAccessoryProfile(local)

        #expect(resolved == conflictRemote.normalized())
        #expect(transport.savedRecords.count == 1)
    }

    @Test
    func testMissingRecordRetriesAreBounded() async {
        let local = makeProfile(time: 20, writer: "local")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .failure(TerminalAccessoryRecordTransportTestError.missing)
        )
        transport.saveResults = Array(
            repeating: .failure(TerminalAccessoryRecordTransportTestError.missing),
            count: TerminalAccessoryCloudKitClient.maximumConflictAttempts
        )
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        do {
            _ = try await client.syncTerminalAccessoryProfile(local)
            Issue.record("Expected bounded retry failure")
        } catch {
            #expect(error as? TerminalAccessoryCloudClientError == .conflictRetryLimitReached)
        }

        #expect(
            transport.savedRecords.count
                == TerminalAccessoryCloudKitClient.maximumConflictAttempts
        )
    }

    @Test
    func testUnclassifiedFailureIsNotRetried() async {
        let local = makeProfile(time: 20, writer: "local")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .failure(TerminalAccessoryRecordTransportTestError.failed)
        )
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        do {
            _ = try await client.syncTerminalAccessoryProfile(local)
            Issue.record("Expected transport failure")
        } catch {
            guard error as? TerminalAccessoryRecordTransportTestError == .failed else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(transport.savedRecords.isEmpty)
    }

    @Test
    func testPendingHandlerUsesInjectedClientAndPublishesResolution() async throws {
        let queued = makeProfile(time: 10, writer: "queued")
        let resolved = makeProfile(time: 20, writer: "resolved")
        let client = TerminalAccessoryCloudClientSpy(resolvedProfile: resolved)
        let publisher = TerminalAccessoryResolutionPublisherSpy()
        let handler = TerminalAccessoryPendingMutationHandler(
            cloud: client,
            resolutionPublisher: publisher
        )

        try await handler.handle(queued)

        #expect(client.receivedProfiles == [queued])
        #expect(publisher.profiles == [resolved])
    }

    private func record(for profile: TerminalAccessoryProfile) throws -> CKRecord {
        try TerminalAccessoryCloudKitRecordCodec.record(
            for: profile,
            recordID: TerminalAccessoryCloudKitRecordCodec.recordID(
                in: CKRecordZone.ID(
                    zoneName: "TerminalAccessoryClientTests",
                    ownerName: CKCurrentUserDefaultName
                )
            )
        )
    }

    private func makeProfile(
        time: TimeInterval,
        writer: String
    ) -> TerminalAccessoryProfile {
        var profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: writer)
        let date = Date(timeIntervalSince1970: time)
        profile.layout.updatedAt = date
        profile.updatedAt = date
        return profile.normalized()
    }
}
