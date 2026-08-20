import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class AppServerMutationClientStub: ServerRemoteMutationClient {
    private(set) var events: [String] = []

    func saveServer(_ server: Server) async throws {
        events.append("saveServer:\(server.id)")
    }

    func deleteServer(_ server: Server) async throws {
        events.append("deleteServer:\(server.id)")
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        events.append("saveWorkspace:\(workspace.id)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        events.append("deleteWorkspace:\(workspace.id)")
    }
}

@MainActor
private final class AppThemeMutationClientStub: TerminalThemeCloudMutationClient {
    private(set) var themes: [TerminalTheme] = []
    private(set) var preferences: [TerminalThemePreference] = []

    func saveTerminalTheme(_ theme: TerminalTheme) async throws {
        themes.append(theme)
    }

    func saveTerminalThemePreference(_ preference: TerminalThemePreference) async throws {
        preferences.append(preference)
    }
}

@MainActor
private final class AppAccessoryCloudClientStub: TerminalAccessoryCloudClient {
    private(set) var profiles: [TerminalAccessoryProfile] = []

    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        profiles.append(localProfile)
        return localProfile
    }
}

@MainActor
private final class AppStatsCloudClientStub: StatsPreferencesCloudClient {
    private(set) var preferences: [StatsPreferences] = []

    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences {
        preferences.append(localPreferences)
        return localPreferences
    }
}

@MainActor
struct CloudKitSyncLiveCompositionTests {
    @Test
    func clientCompositionPreservesInjectedIdentities() {
        let suiteName = "CloudKitSyncLiveCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = AppServerMutationClientStub()
        let theme = AppThemeMutationClientStub()
        let accessory = AppAccessoryCloudClientStub()
        let stats = AppStatsCloudClientStub()
        let generation = UUID()
        let clients = CloudKitSyncClients(
            serverCloud: server,
            terminalThemeCloud: theme,
            terminalAccessoryCloud: accessory,
            statsPreferencesCloud: stats
        )
        let composition = CloudKitSyncLiveComposition.make(
            clients: clients,
            queue: PendingCloudKitSyncQueue(
                storageKey: "compositionQueue",
                defaults: defaults
            ),
            isSyncEnabled: { false },
            currentGeneration: { generation },
            now: { Date(timeIntervalSinceReferenceDate: 1_000) },
            makeID: UUID.init
        )

        #expect(clients.serverCloud === server)
        #expect(clients.terminalThemeCloud === theme)
        #expect(clients.terminalAccessoryCloud === accessory)
        #expect(clients.statsPreferencesCloud === stats)
        #expect(composition.coordinator.snapshot().isEmpty)
    }

    @Test
    func coordinatorDispatchesEveryMutationAndPublishesResolvedValues() async throws {
        let suiteName = "CloudKitSyncDispatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serverClient = AppServerMutationClientStub()
        let themeClient = AppThemeMutationClientStub()
        let accessoryClient = AppAccessoryCloudClientStub()
        let statsClient = AppStatsCloudClientStub()
        let generation = UUID()
        let composition = CloudKitSyncLiveComposition.make(
            clients: CloudKitSyncClients(
                serverCloud: serverClient,
                terminalThemeCloud: themeClient,
                terminalAccessoryCloud: accessoryClient,
                statsPreferencesCloud: statsClient
            ),
            queue: PendingCloudKitSyncQueue(
                storageKey: "dispatchQueue",
                defaults: defaults
            ),
            isSyncEnabled: { true },
            currentGeneration: { generation },
            now: { Date(timeIntervalSinceReferenceDate: 10_000) },
            makeID: UUID.init
        )
        let terminalAccessoryResolutions = composition.terminalAccessoryResolutions
        let statsPreferencesResolutions = composition.statsPreferencesResolutions
        var publishedProfiles: [TerminalAccessoryProfile] = []
        var publishedStats: [StatsPreferences] = []
        let accessoryObserverID = terminalAccessoryResolutions
            .observeTerminalAccessoryProfile { profile in
                publishedProfiles.append(profile)
            }
        let statsObserverID = statsPreferencesResolutions
            .observeStatsPreferences { preferences in
                publishedStats.append(preferences)
            }
        defer {
            terminalAccessoryResolutions.removeTerminalAccessoryProfileObserver(
                accessoryObserverID
            )
            statsPreferencesResolutions.removeStatsPreferencesObserver(statsObserverID)
        }
        let coordinator = composition.coordinator
        let workspace = makeWorkspace(name: "Saved Workspace")
        let deletedWorkspace = makeWorkspace(name: "Deleted Workspace")
        let server = makeServer(workspaceID: workspace.id, name: "Saved Server")
        let deletedServer = makeServer(
            workspaceID: deletedWorkspace.id,
            name: "Deleted Server"
        )
        let theme = TerminalTheme(
            name: "Queued Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let preference = TerminalThemePreference(
            darkThemeName: "Queued Theme",
            lightThemeName: "Queued Theme",
            usePerAppearanceTheme: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let profile = makeProfile()
        let stats = makeStatsPreferences()

        try coordinator.enqueueServerUpsert(server)
        try coordinator.enqueueServerDelete(deletedServer)
        try coordinator.enqueueWorkspaceUpsert(workspace)
        try coordinator.enqueueWorkspaceDelete(deletedWorkspace)
        try coordinator.enqueueTerminalThemeUpsert(theme)
        try coordinator.enqueueTerminalThemePreferenceUpsert(preference)
        try coordinator.enqueueTerminalAccessoryProfileUpsert(profile)
        try coordinator.enqueueStatsPreferencesUpsert(stats)
        await coordinator.drainPendingMutations()

        #expect(serverClient.events == [
            "saveWorkspace:\(workspace.id)",
            "saveServer:\(server.id)",
            "deleteServer:\(deletedServer.id)",
            "deleteWorkspace:\(deletedWorkspace.id)"
        ])
        #expect(themeClient.themes == [theme])
        #expect(themeClient.preferences == [preference])
        #expect(accessoryClient.profiles == [profile])
        #expect(statsClient.preferences == [stats])
        #expect(publishedProfiles == [profile])
        #expect(publishedStats == [stats])
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func unsupportedPayloadRemainsQueuedAfterRealRouterFailure() async throws {
        let suiteName = "CloudKitSyncUnsupportedPayloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let generation = UUID()
        let composition = CloudKitSyncLiveComposition.make(
            clients: CloudKitSyncClients(
                serverCloud: AppServerMutationClientStub(),
                terminalThemeCloud: AppThemeMutationClientStub(),
                terminalAccessoryCloud: AppAccessoryCloudClientStub(),
                statsPreferencesCloud: AppStatsCloudClientStub()
            ),
            queue: PendingCloudKitSyncQueue(
                storageKey: "unsupportedPayloadQueue",
                defaults: defaults
            ),
            isSyncEnabled: { true },
            currentGeneration: { generation },
            now: { now },
            makeID: UUID.init
        )
        let payload = try PendingCloudKitPayloadEnvelope(
            entityType: "unknown",
            entityKey: "unknown-record",
            operation: .upsert,
            drainPriority: 99,
            value: ["value": "unsupported"]
        )

        try composition.coordinator.enqueue(payload)
        await composition.coordinator.drainPendingMutations()

        let retainedMutation = try #require(composition.coordinator.snapshot().first)
        #expect(composition.coordinator.snapshot().count == 1)
        #expect(retainedMutation.payload == payload)
        #expect(retainedMutation.retryCount == 1)
        #expect(retainedMutation.nextRetryAt == now.addingTimeInterval(30))
        #expect(retainedMutation.lastErrorDescription?.contains("Unsupported") == true)
    }

    @Test
    func resolutionChannelsAreIsolatedAndRemovedObserversStayRemoved() {
        let terminalAccessoryResolutions = TerminalAccessoryResolutionChannel()
        let statsPreferencesResolutions = StatsPreferencesResolutionChannel()
        let profile = makeProfile()
        let stats = makeStatsPreferences()
        var publishedProfiles: [TerminalAccessoryProfile] = []
        var publishedStats: [StatsPreferences] = []
        let accessoryObserverID = terminalAccessoryResolutions
            .observeTerminalAccessoryProfile { publishedProfiles.append($0) }
        let statsObserverID = statsPreferencesResolutions
            .observeStatsPreferences { publishedStats.append($0) }

        terminalAccessoryResolutions.publishTerminalAccessoryProfile(profile)

        #expect(publishedProfiles == [profile])
        #expect(publishedStats.isEmpty)

        statsPreferencesResolutions.publishStatsPreferences(stats)

        #expect(publishedProfiles == [profile])
        #expect(publishedStats == [stats])

        terminalAccessoryResolutions.removeTerminalAccessoryProfileObserver(
            accessoryObserverID
        )
        statsPreferencesResolutions.removeStatsPreferencesObserver(statsObserverID)
        terminalAccessoryResolutions.publishTerminalAccessoryProfile(profile)
        statsPreferencesResolutions.publishStatsPreferences(stats)

        #expect(publishedProfiles == [profile])
        #expect(publishedStats == [stats])
    }

    private func makeServer(workspaceID: UUID, name: String) -> Server {
        Server(
            workspaceId: workspaceID,
            name: name,
            host: "server.example.test",
            username: "tester"
        )
    }

    private func makeWorkspace(name: String) -> Workspace {
        Workspace(name: name)
    }

    private func makeProfile() -> TerminalAccessoryProfile {
        TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "device")
    }

    private func makeStatsPreferences() -> StatsPreferences {
        StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSinceReferenceDate: 300),
            lastWriterDeviceId: "device"
        )
    }
}
