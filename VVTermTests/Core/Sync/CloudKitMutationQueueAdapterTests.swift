import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class MutationQueueAdapterHandler: PendingCloudKitMutationHandling {
    func handle(_ mutation: PendingCloudKitMutation) async throws {}
}

@MainActor
struct CloudKitMutationQueueAdapterTests {
    @Test
    func serverAdapterMapsEveryOperationAndClearsOnlyServerMutations() throws {
        let fixture = makeFixture(storageKey: "serverAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let coordinator = fixture.coordinator
        let repository: any ServerSyncRepository = coordinator
        let workspace = makeWorkspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Saved Workspace"
        )
        let deletedWorkspace = makeWorkspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Deleted Workspace"
        )
        let server = makeServer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceID: workspace.id,
            name: "Saved Server"
        )
        let deletedServer = makeServer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceID: deletedWorkspace.id,
            name: "Deleted Server"
        )
        let stats = makeStatsPreferences()
        let statsPayload = try PendingCloudKitMutationPayload.statsPreferencesUpsert(stats)
        let unrelatedMutation = PendingCloudKitMutation(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            payload: statsPayload,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        try coordinator.enqueue(unrelatedMutation)

        try repository.enqueueServerDataMutations([
            ServerPendingMutation(
                id: UUID(),
                payload: .serverUpsert(server),
                createdAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            ServerPendingMutation(
                id: UUID(),
                payload: .serverDelete(deletedServer),
                createdAt: Date(timeIntervalSinceReferenceDate: 3)
            ),
            ServerPendingMutation(
                id: UUID(),
                payload: .workspaceUpsert(workspace),
                createdAt: Date(timeIntervalSinceReferenceDate: 4)
            ),
            ServerPendingMutation(
                id: UUID(),
                payload: .workspaceDelete(deletedWorkspace),
                createdAt: Date(timeIntervalSinceReferenceDate: 5)
            )
        ])

        let expectedPayloads = [
            statsPayload,
            try PendingCloudKitMutationPayload.serverUpsert(server),
            try PendingCloudKitMutationPayload.serverDelete(deletedServer),
            try PendingCloudKitMutationPayload.workspaceUpsert(workspace),
            try PendingCloudKitMutationPayload.workspaceDelete(deletedWorkspace)
        ]
        let expectedServerPayloads: [ServerPendingMutation.Payload] = [
            .serverUpsert(server),
            .serverDelete(deletedServer),
            .workspaceUpsert(workspace),
            .workspaceDelete(deletedWorkspace)
        ]
        #expect(coordinator.snapshot().map(\.payload) == expectedPayloads)
        let pendingServerMutations = try repository.pendingServerMutations()
        #expect(pendingServerMutations.map(\.payload) == expectedServerPayloads)

        let firstServerMutation = try #require(pendingServerMutations.first)
        try repository.removePendingServerMutation(firstServerMutation.id)
        try repository.clearPendingServerAndWorkspaceMutations()

        #expect(coordinator.snapshot() == [unrelatedMutation])
    }

    @Test
    func serverAdapterPreservesAtomicDeletionMutationIdentityAndOrder() throws {
        let fixture = makeFixture(storageKey: "serverAtomicAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let repository: any ServerSyncRepository = fixture.coordinator
        let workspace = makeWorkspace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            name: "Deleted Workspace"
        )
        let server = makeServer(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            workspaceID: workspace.id,
            name: "Deleted Server"
        )
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let serverMutation = ServerPendingMutation(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!,
            payload: .serverDelete(server),
            createdAt: createdAt
        )
        let workspaceMutation = ServerPendingMutation(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000011")!,
            payload: .workspaceDelete(workspace),
            createdAt: createdAt
        )

        try repository.enqueueServerDataMutations([
            serverMutation,
            workspaceMutation
        ])

        let serverPayload = try PendingCloudKitMutationPayload.serverDelete(server)
        let workspacePayload = try PendingCloudKitMutationPayload.workspaceDelete(workspace)
        let expectedMutations = [
            PendingCloudKitMutation(
                id: serverMutation.id,
                payload: serverPayload,
                createdAt: createdAt
            ),
            PendingCloudKitMutation(
                id: workspaceMutation.id,
                payload: workspacePayload,
                createdAt: createdAt
            )
        ]
        #expect(fixture.coordinator.snapshot() == expectedMutations)
    }

    @Test
    func themeAdapterMapsThemeAndPreferenceUpserts() throws {
        let fixture = makeFixture(storageKey: "themeAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let queue: any TerminalThemeMutationQueue = fixture.coordinator
        let theme = TerminalTheme(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            name: "Queued Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 3_000)
        )
        let preference = TerminalThemePreference(
            darkThemeName: theme.name,
            lightThemeName: theme.name,
            usePerAppearanceTheme: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 3_001)
        )

        try queue.enqueueTerminalThemeUpsert(theme)
        try queue.enqueueTerminalThemePreferenceUpsert(preference)

        let expectedPayloads = [
            try PendingCloudKitMutationPayload.terminalThemeUpsert(theme),
            try PendingCloudKitMutationPayload.terminalThemePreferenceUpsert(preference)
        ]
        #expect(fixture.coordinator.snapshot().map(\.payload) == expectedPayloads)
    }

    @Test
    func accessoryAdapterMapsProfileUpsert() throws {
        let fixture = makeFixture(storageKey: "accessoryAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let queue: any TerminalAccessoryMutationQueue = fixture.coordinator
        let profile = TerminalAccessoryProfile.defaultValue(
            lastWriterDeviceId: "accessory-writer"
        )

        try queue.enqueueTerminalAccessoryProfileUpsert(profile)

        let expectedPayload = try PendingCloudKitMutationPayload
            .terminalAccessoryProfileUpsert(profile)
        #expect(fixture.coordinator.snapshot().map(\.payload) == [expectedPayload])
    }

    @Test
    func statsAdapterMapsPreferencesUpsert() throws {
        let fixture = makeFixture(storageKey: "statsAdapter")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let queue: any StatsPreferencesMutationQueue = fixture.coordinator
        let preferences = makeStatsPreferences()

        try queue.enqueueStatsPreferencesUpsert(preferences)

        let expectedPayload = try PendingCloudKitMutationPayload
            .statsPreferencesUpsert(preferences)
        #expect(fixture.coordinator.snapshot().map(\.payload) == [expectedPayload])
    }

    @Test
    func adaptersPropagatePersistenceFailuresWithoutChangingMemory() throws {
        let suiteName = "CloudKitMutationQueueAdapterTests.failure.\(UUID().uuidString)"
        let defaults = WriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: MutationQueueAdapterHandler(),
            queue: PendingCloudKitSyncQueue(
                storageKey: "adapterFailure",
                defaults: defaults
            ),
            isSyncEnabled: { false },
            currentGeneration: UUID.init,
            now: { Date(timeIntervalSinceReferenceDate: 6_000) },
            makeID: { UUID(uuidString: "50000000-0000-0000-0000-000000000001")! }
        )
        let workspace = makeWorkspace(id: UUID(), name: "Workspace")
        let server = makeServer(id: UUID(), workspaceID: workspace.id, name: "Server")
        let theme = TerminalTheme(
            name: "Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let profile = TerminalAccessoryProfile.defaultValue(
            lastWriterDeviceId: "accessory-writer"
        )
        let preferences = makeStatsPreferences()

        defaults.rejectWrites = true

        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try coordinator.enqueueServerUpsert(server)
        }
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try coordinator.enqueueTerminalThemeUpsert(theme)
        }
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try coordinator.enqueueTerminalAccessoryProfileUpsert(profile)
        }
        #expect(throws: PendingCloudKitSyncQueueError.self) {
            try coordinator.enqueueStatsPreferencesUpsert(preferences)
        }
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func adaptersUseCoordinatorIdentityAndClock() throws {
        let suiteName = "CloudKitMutationQueueAdapterTests.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expectedID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let expectedDate = Date(timeIntervalSinceReferenceDate: 7_000)
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: MutationQueueAdapterHandler(),
            queue: PendingCloudKitSyncQueue(
                storageKey: "adapterIdentity",
                defaults: defaults
            ),
            isSyncEnabled: { false },
            currentGeneration: UUID.init,
            now: { expectedDate },
            makeID: { expectedID }
        )
        let preferences = makeStatsPreferences()

        try coordinator.enqueueStatsPreferencesUpsert(preferences)

        let mutation = try #require(coordinator.snapshot().first)
        let expectedPayload = try PendingCloudKitMutationPayload
            .statsPreferencesUpsert(preferences)
        #expect(mutation.id == expectedID)
        #expect(mutation.createdAt == expectedDate)
        #expect(mutation.payload == expectedPayload)
    }

    private func makeFixture(
        storageKey: String
    ) -> (
        coordinator: CloudKitSyncCoordinator,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "CloudKitMutationQueueAdapterTests.\(storageKey).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            CloudKitSyncCoordinator(
                mutationHandler: MutationQueueAdapterHandler(),
                queue: PendingCloudKitSyncQueue(
                    storageKey: storageKey,
                    defaults: defaults
                ),
                isSyncEnabled: { false },
                currentGeneration: UUID.init,
                now: { Date(timeIntervalSinceReferenceDate: 5_000) },
                makeID: UUID.init
            ),
            defaults,
            suiteName
        )
    }

    private func makeWorkspace(id: UUID, name: String) -> Workspace {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        return Workspace(
            id: id,
            name: name,
            createdAt: date,
            updatedAt: date
        )
    }

    private func makeServer(id: UUID, workspaceID: UUID, name: String) -> Server {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        return Server(
            id: id,
            workspaceId: workspaceID,
            name: name,
            host: "server.example.test",
            username: "tester",
            createdAt: date,
            updatedAt: date
        )
    }

    private func makeStatsPreferences() -> StatsPreferences {
        StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSinceReferenceDate: 4_000),
            lastWriterDeviceId: "stats-writer"
        )
    }
}
