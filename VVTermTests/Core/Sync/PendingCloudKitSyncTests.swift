import Combine
import Foundation
import Testing
@testable import VVTerm

struct PendingCloudKitSyncTests {
    @Test
    func queueSummaryPublishesEnqueueFailureAndRemoval() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        var summaries: [PendingCloudKitQueueSummary] = []
        let observation = queue.summaryUpdates.sink { summaries.append($0) }
        defer { observation.cancel() }
        let mutation = PendingCloudKitMutation(
            payload: try .serverUpsert(fixtures.server)
        )

        try queue.enqueue(mutation)
        try queue.recordFailure(
            for: mutation,
            error: RetryTestError(),
            at: fixtures.createdAt
        )
        try queue.remove(mutation.id)

        #expect(summaries.count == 4)
        #expect(summaries[0] == .empty)
        #expect(summaries[1].pendingOperationCount == 1)
        #expect(!summaries[1].hasPendingFailure)
        #expect(summaries[2].pendingOperationCount == 1)
        #expect(summaries[2].hasPendingFailure)
        #expect(summaries[3] == .empty)
    }

    @Test
    func everySupportedMutationRoundTrips() throws {
        let fixtures = PendingSyncFixtures()

        for (index, payload) in try fixtures.supportedPayloads().enumerated() {
            let mutation = PendingCloudKitMutation(
                id: fixtures.mutationIDs[index],
                payload: payload,
                createdAt: fixtures.createdAt.addingTimeInterval(TimeInterval(index)),
                retryCount: index,
                nextRetryAt: fixtures.createdAt.addingTimeInterval(120),
                lastErrorCode: "error-\(index)",
                lastErrorDescription: "failure-\(index)"
            )

            let encoded = try JSONEncoder().encode(mutation)
            let decoded = try JSONDecoder().decode(PendingCloudKitMutation.self, from: encoded)

            #expect(decoded == mutation)
        }
    }

    @Test
    func previouslyPersistedAssociatedPayloadMigrates() throws {
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let data = Data(#"""
        [
        {
          "id": "10000000-0000-0000-0000-000000000001",
          "payload": {
            "kind": "terminalThemeUpsert",
            "payload": {
              "id": "20000000-0000-0000-0000-000000000002",
              "name": "Durable Theme",
              "content": "background = #000000\nforeground = #FFFFFF\n",
              "updatedAt": 1234
            }
          },
          "createdAt": 1000,
          "retryCount": 2,
          "nextRetryAt": 1060,
          "lastErrorCode": "networkFailure",
          "lastErrorDescription": "offline"
        }
        ]
        """#.utf8)

        storage.defaults.set(data, forKey: storage.storageKey)
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults,
            legacyMigrator: CloudKitPendingMutationLegacyMigrator()
        )
        let mutation = try #require(queue.snapshot().first)
        let expectedTheme = TerminalTheme(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Durable Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_234)
        )

        #expect(mutation.id == UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let expectedPayload = try PendingCloudKitMutationPayload.terminalThemeUpsert(expectedTheme)
        #expect(mutation.payload == expectedPayload)
        #expect(mutation.createdAt == Date(timeIntervalSinceReferenceDate: 1_000))
        #expect(mutation.retryCount == 2)
        #expect(mutation.nextRetryAt == Date(timeIntervalSinceReferenceDate: 1_060))
        #expect(mutation.lastErrorCode == "networkFailure")
        #expect(mutation.lastErrorDescription == "offline")
    }

    @Test
    func migrationPersistenceFailureBlocksNewMutationsUntilRetry() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeRejectingStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let legacyData = try JSONSerialization.data(
            withJSONObject: [try jsonObject(LegacyMutationFixture(
                id: fixtures.mutationIDs[0],
                entity: "server",
                operation: "upsert",
                entityKey: fixtures.server.id.uuidString,
                server: fixtures.server
            ))]
        )
        storage.defaults.set(legacyData, forKey: storage.storageKey)
        storage.defaults.rejectWrites = true

        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults,
            legacyMigrator: CloudKitPendingMutationLegacyMigrator()
        )
        let newMutation = PendingCloudKitMutation(
            payload: try .workspaceUpsert(fixtures.workspace)
        )

        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try queue.enqueue(newMutation)
        }
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try queue.remove(fixtures.mutationIDs[0])
        }
        #expect(queue.summary.health == .migrationBlocked)
        #expect(storage.defaults.data(forKey: storage.storageKey) == legacyData)

        storage.defaults.rejectWrites = false
        try queue.retryMigration()
        try queue.enqueue(newMutation)

        #expect(queue.snapshot().map(\.id) == [fixtures.mutationIDs[0], newMutation.id])
        #expect(queue.summary.health == .ready)
    }

    @Test
    func everyAssociatedLegacyPayloadMigratesWithoutQuarantine() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

        let legacyRecords = try fixtures.associatedLegacyRecords()
        storage.defaults.set(
            try JSONSerialization.data(withJSONObject: legacyRecords),
            forKey: storage.storageKey
        )

        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults,
            legacyMigrator: CloudKitPendingMutationLegacyMigrator()
        )
        let expectedPayloads: [PendingCloudKitMutationPayload] = [
            try .serverUpsert(fixtures.server),
            try .serverDelete(fixtures.legacyDeletedServer),
            try .workspaceUpsert(fixtures.workspace),
            try .workspaceDelete(fixtures.deletedWorkspace),
            try .terminalThemeUpsert(fixtures.theme),
            try .terminalThemePreferenceUpsert(fixtures.themePreference),
            try .terminalAccessoryProfileUpsert(fixtures.accessoryProfile),
            try .statsPreferencesUpsert(fixtures.statsPreferences)
        ]

        #expect(queue.snapshot().map(\.payload) == expectedPayloads)
        #expect(queue.snapshot().map(\.id) == Array(fixtures.mutationIDs.prefix(8)))
        #expect(queue.snapshot().allSatisfy { $0.retryCount == 2 })
        #expect(queue.quarantineSnapshot().isEmpty)
    }

    @Test
    func everyValidLegacyCombinationMigratesWithoutQuarantine() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

        let legacyMutations = fixtures.validLegacyMutations
        storage.defaults.set(try JSONEncoder().encode(legacyMutations), forKey: storage.storageKey)

        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults,
            legacyMigrator: CloudKitPendingMutationLegacyMigrator()
        )

        let expectedPayloads = try fixtures.migratedLegacyPayloads()
        #expect(queue.snapshot().map(\.payload) == expectedPayloads)
        #expect(queue.snapshot().map(\.id) == Array(fixtures.mutationIDs.prefix(9)))
        #expect(queue.snapshot().allSatisfy { $0.retryCount == 2 })
        #expect(queue.quarantineSnapshot().isEmpty)

        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
        #expect(reloadedQueue.quarantineSnapshot().isEmpty)
    }

    @Test
    func invalidLegacyRecordsAreQuarantinedWithoutLosingValidRecords() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

        let valid = LegacyMutationFixture(
            id: fixtures.mutationIDs[0],
            entity: "server",
            operation: "upsert",
            entityKey: fixtures.server.id.uuidString,
            server: fixtures.server
        )
        let missingPayload = LegacyMutationFixture(
            id: fixtures.mutationIDs[1],
            entity: "workspace",
            operation: "upsert",
            entityKey: fixtures.workspace.id.uuidString
        )
        let conflictingPayloads = LegacyMutationFixture(
            id: fixtures.mutationIDs[2],
            entity: "server",
            operation: "upsert",
            entityKey: fixtures.server.id.uuidString,
            server: fixtures.server,
            workspace: fixtures.workspace
        )
        let mismatchedEntityKey = LegacyMutationFixture(
            id: fixtures.mutationIDs[3],
            entity: "workspace",
            operation: "delete",
            entityKey: UUID().uuidString,
            workspace: fixtures.deletedWorkspace
        )
        let unsupportedDelete = LegacyMutationFixture(
            id: fixtures.mutationIDs[4],
            entity: "terminalAccessoryProfile",
            operation: "delete",
            entityKey: TerminalAccessoryProfile.recordName
        )

        let records: [Any] = try [
            valid,
            missingPayload,
            conflictingPayloads,
            mismatchedEntityKey,
            unsupportedDelete
        ].map(jsonObject) + ["unreadable legacy mutation"]
        let legacyData = try JSONSerialization.data(withJSONObject: records)
        storage.defaults.set(legacyData, forKey: storage.storageKey)

        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults,
            legacyMigrator: CloudKitPendingMutationLegacyMigrator()
        )

        let expectedPayload = try PendingCloudKitMutationPayload.serverUpsert(fixtures.server)
        #expect(queue.snapshot().map(\.payload) == [expectedPayload])
        #expect(queue.quarantineSnapshot().count == 5)
        #expect(queue.summary.quarantinedOperationCount == 5)
        #expect(queue.summary.health == .ready)
        #expect(queue.quarantineSnapshot().allSatisfy { !$0.encodedLegacyRecord.isEmpty })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .missingOrConflictingPayload })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .mismatchedEntityKey })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .unsupportedOperation })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .unreadableLegacyRecord })

        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
        #expect(reloadedQueue.quarantineSnapshot() == queue.quarantineSnapshot())
    }

    @Test
    func retryCountAndExponentialDelaySaturate() throws {
        let fixtures = PendingSyncFixtures()
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let error = RetryTestError()

        let firstFailure = PendingCloudKitMutation(
            payload: try .serverUpsert(fixtures.server)
        ).withFailure(error: error, at: now)
        #expect(firstFailure.retryCount == 1)
        #expect(firstFailure.nextRetryAt == now.addingTimeInterval(30))

        let negativeCount = PendingCloudKitMutation(
            payload: try .serverUpsert(fixtures.server),
            retryCount: Int.min
        )
        #expect(negativeCount.retryCount == 0)

        let cappedDelay = PendingCloudKitMutation(
            payload: try .serverUpsert(fixtures.server),
            retryCount: 7
        ).withFailure(error: error, at: now)
        #expect(cappedDelay.retryCount == 8)
        #expect(cappedDelay.nextRetryAt == now.addingTimeInterval(3_600))

        let saturatedCount = PendingCloudKitMutation(
            payload: try .serverUpsert(fixtures.server),
            retryCount: Int.max
        )
        #expect(saturatedCount.retryCount == PendingCloudKitMutation.maximumRetryCount)

        let saturatedFailure = saturatedCount.withFailure(error: error, at: now)
        #expect(saturatedFailure.retryCount == PendingCloudKitMutation.maximumRetryCount)
        #expect(saturatedFailure.nextRetryAt == now.addingTimeInterval(3_600))
    }

    @Test
    func enqueueCoalescesOnlyTheSameEntityAndKey() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )

        try queue.enqueue(PendingCloudKitMutation(payload: .serverUpsert(fixtures.server)))
        try queue.enqueue(
            PendingCloudKitMutation(payload: .workspaceUpsert(fixtures.workspaceWithServerID))
        )
        try queue.enqueue(PendingCloudKitMutation(payload: .serverDelete(fixtures.deletedServer)))

        let firstExpectedPayloads = [
            try PendingCloudKitMutationPayload.workspaceUpsert(fixtures.workspaceWithServerID),
            try PendingCloudKitMutationPayload.serverDelete(fixtures.deletedServer)
        ]
        #expect(queue.snapshot().map(\.payload) == firstExpectedPayloads)

        try queue.enqueue(
            PendingCloudKitMutation(
                payload: .workspaceDelete(fixtures.deletedWorkspaceWithServerID)
            )
        )
        let finalExpectedPayloads = [
            try PendingCloudKitMutationPayload.serverDelete(fixtures.deletedServer),
            try PendingCloudKitMutationPayload.workspaceDelete(fixtures.deletedWorkspaceWithServerID)
        ]
        #expect(queue.snapshot().map(\.payload) == finalExpectedPayloads)

        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
    }

    @Test
    func atomicBatchCoalescesAllMutationsBeforeOnePersistedSnapshot() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        try queue.enqueue(PendingCloudKitMutation(payload: .serverUpsert(fixtures.server)))
        try queue.enqueue(
            PendingCloudKitMutation(payload: .workspaceUpsert(fixtures.workspaceWithServerID))
        )

        try queue.enqueueAtomically([
            PendingCloudKitMutation(payload: .serverDelete(fixtures.deletedServer)),
            PendingCloudKitMutation(
                payload: .workspaceDelete(fixtures.deletedWorkspaceWithServerID)
            )
        ])

        let expectedPayloads = [
            try PendingCloudKitMutationPayload.serverDelete(fixtures.deletedServer),
            try PendingCloudKitMutationPayload.workspaceDelete(fixtures.deletedWorkspaceWithServerID)
        ]
        #expect(queue.snapshot().map(\.payload) == expectedPayloads)
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
    }

    @Test
    func enqueuePersistenceFailureLeavesMemoryAndDiskUnchanged() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeRejectingStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        let original = PendingCloudKitMutation(payload: try .serverUpsert(fixtures.server))
        try queue.enqueue(original)

        storage.defaults.rejectWrites = true
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try queue.enqueue(
                PendingCloudKitMutation(payload: .workspaceUpsert(fixtures.workspace))
            )
        }

        #expect(queue.snapshot() == [original])
        storage.defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == [original])
    }

    @Test
    func removalPersistenceFailureLeavesMemoryAndDiskUnchanged() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeRejectingStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        let mutation = PendingCloudKitMutation(payload: try .serverUpsert(fixtures.server))
        try queue.enqueue(mutation)

        storage.defaults.rejectWrites = true
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try queue.remove(mutation.id)
        }

        #expect(queue.snapshot() == [mutation])
        storage.defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == [mutation])
    }

    @Test
    func retryPersistenceFailureLeavesMemoryAndDiskUnchanged() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeRejectingStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        let mutation = PendingCloudKitMutation(payload: try .serverUpsert(fixtures.server))
        try queue.enqueue(mutation)

        storage.defaults.rejectWrites = true
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try queue.recordFailure(
                for: mutation,
                error: RetryTestError(),
                at: fixtures.createdAt
            )
        }

        #expect(queue.snapshot() == [mutation])
        storage.defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == [mutation])
    }

    @Test
    func drainOrderPreservesDependenciesAndDefersDeletes() throws {
        let fixtures = PendingSyncFixtures()
        let mutations = try fixtures.supportedPayloads().reversed().enumerated().map { index, payload in
            PendingCloudKitMutation(
                id: fixtures.mutationIDs[index],
                payload: payload,
                createdAt: fixtures.createdAt
            )
        }

        let orderedPayloads = mutations
            .sorted(by: PendingCloudKitMutation.drainsBefore)
            .map(\.payload)

        let expectedDrainOrder = try fixtures.payloadsInDrainOrder()
        #expect(orderedPayloads == expectedDrainOrder)

        let later = PendingCloudKitMutation(
            id: fixtures.mutationIDs[1],
            payload: try .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt.addingTimeInterval(1)
        )
        let earlier = PendingCloudKitMutation(
            id: fixtures.mutationIDs[2],
            payload: try .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt
        )
        #expect([later, earlier].sorted(by: PendingCloudKitMutation.drainsBefore) == [earlier, later])

        let lowerID = PendingCloudKitMutation(
            id: fixtures.mutationIDs[0],
            payload: try .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt
        )
        let higherID = PendingCloudKitMutation(
            id: fixtures.mutationIDs[1],
            payload: try .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt
        )
        #expect(
            [higherID, lowerID].sorted(by: PendingCloudKitMutation.drainsBefore) == [lowerID, higherID]
        )
    }
}

private struct PendingSyncFixtures {
    let createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
    let mutationIDs = (1...12).map {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
    }

    let workspace: Workspace
    let deletedWorkspace: Workspace
    let server: Server
    let deletedServer: Server
    let legacyDeletedServer: Server
    let workspaceWithServerID: Workspace
    let deletedWorkspaceWithServerID: Workspace
    let theme: TerminalTheme
    let legacyDeletedTheme: TerminalTheme
    let themePreference: TerminalThemePreference
    let accessoryProfile: TerminalAccessoryProfile
    let statsPreferences: StatsPreferences

    init() {
        let createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let workspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let deletedWorkspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let serverID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

        workspace = Workspace(
            id: workspaceID,
            name: "Primary",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        deletedWorkspace = Workspace(
            id: deletedWorkspaceID,
            name: "Removed",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        server = Server(
            id: serverID,
            workspaceId: workspaceID,
            name: "Production",
            host: "example.test",
            username: "tester",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        deletedServer = Server(
            id: serverID,
            workspaceId: workspaceID,
            name: "Production",
            host: "example.test",
            username: "tester",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        legacyDeletedServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceId: workspaceID,
            name: "Legacy Removed",
            host: "removed.example.test",
            username: "tester",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        workspaceWithServerID = Workspace(
            id: serverID,
            name: "Same UUID, different entity",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        deletedWorkspaceWithServerID = Workspace(
            id: serverID,
            name: "Same UUID, deleted",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        theme = TerminalTheme(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Queue Theme",
            content: "[colors]\nbackground = '#000000'",
            updatedAt: createdAt
        )
        legacyDeletedTheme = TerminalTheme(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Legacy Delete",
            content: "[colors]\nbackground = '#111111'",
            updatedAt: createdAt.addingTimeInterval(1),
            deletedAt: createdAt.addingTimeInterval(1)
        )
        themePreference = TerminalThemePreference(
            darkThemeName: "Queue Theme",
            lightThemeName: "Queue Theme",
            usePerAppearanceTheme: false,
            updatedAt: createdAt
        )
        accessoryProfile = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: [],
                updatedAt: createdAt
            ),
            customActions: [],
            updatedAt: createdAt,
            lastWriterDeviceId: "test-device"
        )
        statsPreferences = StatsPreferences(
            style: .classic,
            blocks: [],
            updatedAt: createdAt,
            lastWriterDeviceId: "test-device"
        )
    }

    func supportedPayloads() throws -> [PendingCloudKitMutationPayload] {
        [
            try .serverUpsert(server),
            try .serverDelete(deletedServer),
            try .workspaceUpsert(workspace),
            try .workspaceDelete(deletedWorkspace),
            try .terminalThemeUpsert(theme),
            try .terminalThemePreferenceUpsert(themePreference),
            try .terminalAccessoryProfileUpsert(accessoryProfile),
            try .statsPreferencesUpsert(statsPreferences)
        ]
    }

    func payloadsInDrainOrder() throws -> [PendingCloudKitMutationPayload] {
        [
            try .workspaceUpsert(workspace),
            try .serverUpsert(server),
            try .terminalThemeUpsert(theme),
            try .terminalThemePreferenceUpsert(themePreference),
            try .terminalAccessoryProfileUpsert(accessoryProfile),
            try .statsPreferencesUpsert(statsPreferences),
            try .serverDelete(deletedServer),
            try .workspaceDelete(deletedWorkspace)
        ]
    }

    var validLegacyMutations: [LegacyMutationFixture] {
        [
            LegacyMutationFixture(
                id: mutationIDs[0],
                entity: "server",
                operation: "upsert",
                entityKey: server.id.uuidString,
                server: server
            ),
            LegacyMutationFixture(
                id: mutationIDs[1],
                entity: "server",
                operation: "delete",
                entityKey: legacyDeletedServer.id.uuidString,
                server: legacyDeletedServer
            ),
            LegacyMutationFixture(
                id: mutationIDs[2],
                entity: "workspace",
                operation: "upsert",
                entityKey: workspace.id.uuidString,
                workspace: workspace
            ),
            LegacyMutationFixture(
                id: mutationIDs[3],
                entity: "workspace",
                operation: "delete",
                entityKey: deletedWorkspace.id.uuidString,
                workspace: deletedWorkspace
            ),
            LegacyMutationFixture(
                id: mutationIDs[4],
                entity: "terminalTheme",
                operation: "upsert",
                entityKey: theme.id.uuidString,
                terminalTheme: theme
            ),
            LegacyMutationFixture(
                id: mutationIDs[5],
                entity: "terminalTheme",
                operation: "delete",
                entityKey: legacyDeletedTheme.id.uuidString,
                terminalTheme: legacyDeletedTheme
            ),
            LegacyMutationFixture(
                id: mutationIDs[6],
                entity: "terminalThemePreference",
                operation: "upsert",
                entityKey: TerminalThemePreference.recordName,
                terminalThemePreference: themePreference
            ),
            LegacyMutationFixture(
                id: mutationIDs[7],
                entity: "terminalAccessoryProfile",
                operation: "upsert",
                entityKey: TerminalAccessoryProfile.recordName,
                terminalAccessoryProfile: accessoryProfile
            ),
            LegacyMutationFixture(
                id: mutationIDs[8],
                entity: "statsPreferences",
                operation: "upsert",
                entityKey: StatsPreferences.recordName,
                statsPreferences: statsPreferences
            )
        ]
    }

    func migratedLegacyPayloads() throws -> [PendingCloudKitMutationPayload] {
        [
            try .serverUpsert(server),
            try .serverDelete(legacyDeletedServer),
            try .workspaceUpsert(workspace),
            try .workspaceDelete(deletedWorkspace),
            try .terminalThemeUpsert(theme),
            try .terminalThemeUpsert(legacyDeletedTheme),
            try .terminalThemePreferenceUpsert(themePreference),
            try .terminalAccessoryProfileUpsert(accessoryProfile),
            try .statsPreferencesUpsert(statsPreferences)
        ]
    }

    func associatedLegacyRecords() throws -> [Any] {
        [
            try associatedLegacyRecord(
                id: mutationIDs[0],
                kind: "serverUpsert",
                value: server
            ),
            try associatedLegacyRecord(
                id: mutationIDs[1],
                kind: "serverDelete",
                value: legacyDeletedServer
            ),
            try associatedLegacyRecord(
                id: mutationIDs[2],
                kind: "workspaceUpsert",
                value: workspace
            ),
            try associatedLegacyRecord(
                id: mutationIDs[3],
                kind: "workspaceDelete",
                value: deletedWorkspace
            ),
            try associatedLegacyRecord(
                id: mutationIDs[4],
                kind: "terminalThemeUpsert",
                value: theme
            ),
            try associatedLegacyRecord(
                id: mutationIDs[5],
                kind: "terminalThemePreferenceUpsert",
                value: themePreference
            ),
            try associatedLegacyRecord(
                id: mutationIDs[6],
                kind: "terminalAccessoryProfileUpsert",
                value: accessoryProfile
            ),
            try associatedLegacyRecord(
                id: mutationIDs[7],
                kind: "statsPreferencesUpsert",
                value: statsPreferences
            )
        ]
    }
}

private struct LegacyMutationFixture: Encodable {
    let id: UUID
    let entity: String
    let operation: String
    let entityKey: String
    var server: Server? = nil
    var workspace: Workspace? = nil
    var terminalTheme: TerminalTheme? = nil
    var terminalThemePreference: TerminalThemePreference? = nil
    var terminalAccessoryProfile: TerminalAccessoryProfile? = nil
    var statsPreferences: StatsPreferences? = nil
    var createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
    var retryCount = 2
    var nextRetryAt: Date? = Date(timeIntervalSinceReferenceDate: 10_120)
    var lastErrorCode: String? = "legacy-error"
    var lastErrorDescription: String? = "Legacy failure"
}

private struct RetryTestError: Error {}

private func jsonObject(_ fixture: LegacyMutationFixture) throws -> Any {
    let encoded = try JSONEncoder().encode(fixture)
    return try JSONSerialization.jsonObject(with: encoded)
}

private func associatedLegacyRecord<Value: Encodable>(
    id: UUID,
    kind: String,
    value: Value
) throws -> Any {
    let valueData = try JSONEncoder().encode(value)
    let valueObject = try JSONSerialization.jsonObject(with: valueData)
    return [
        "id": id.uuidString,
        "payload": [
            "kind": kind,
            "payload": valueObject
        ],
        "createdAt": 10_000,
        "retryCount": 2,
        "nextRetryAt": 10_120,
        "lastErrorCode": "legacy-error",
        "lastErrorDescription": "Legacy failure"
    ]
}

private func makeStorage() -> (suiteName: String, storageKey: String, defaults: UserDefaults) {
    let suiteName = "PendingCloudKitSyncTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (suiteName, "pending-mutations", defaults)
}

final class WriteRejectingUserDefaults: UserDefaults {
    var rejectWrites = false

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectWrites else { return }
        super.set(value, forKey: defaultName)
    }
}

private func makeRejectingStorage() -> (
    suiteName: String,
    storageKey: String,
    defaults: WriteRejectingUserDefaults
) {
    let suiteName = "PendingCloudKitSyncTests.rejecting.\(UUID().uuidString)"
    let defaults = WriteRejectingUserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (suiteName, "pending-mutations", defaults)
}
