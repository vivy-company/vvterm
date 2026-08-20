import Foundation

@MainActor
struct CloudKitSyncClients {
    let serverCloud: any ServerRemoteMutationClient
    let terminalThemeCloud: any TerminalThemeCloudMutationClient
    let terminalAccessoryCloud: any TerminalAccessoryCloudClient
    let statsPreferencesCloud: any StatsPreferencesCloudClient
}

@MainActor
struct CloudKitSyncComposition {
    let coordinator: CloudKitSyncCoordinator
    let terminalAccessoryResolutions: TerminalAccessoryResolutionChannel
    let statsPreferencesResolutions: StatsPreferencesResolutionChannel
}

@MainActor
struct CloudKitLiveSyncComposition {
    let coordinator: CloudKitSyncCoordinator
    let terminalAccessoryResolutions: TerminalAccessoryResolutionChannel
    let statsPreferencesResolutions: StatsPreferencesResolutionChannel
    let serverCloud: ServerCloudKitClient
    let terminalThemeCloud: TerminalThemeCloudKitClient
    let terminalAccessoryCloud: TerminalAccessoryCloudKitClient
    let statsPreferencesCloud: StatsPreferencesCloudKitClient
}

@MainActor
enum CloudKitSyncLiveComposition {
    static func make(
        clients: CloudKitSyncClients,
        queue: PendingCloudKitSyncQueue,
        isSyncEnabled: @escaping () -> Bool,
        currentGeneration: @escaping () -> UUID,
        now: @escaping () -> Date,
        makeID: @escaping () -> UUID
    ) -> CloudKitSyncComposition {
        let terminalAccessoryResolutions = TerminalAccessoryResolutionChannel()
        let statsPreferencesResolutions = StatsPreferencesResolutionChannel()
        let mutationHandler = CloudKitPendingMutationRouter(
            serverCloud: clients.serverCloud,
            terminalThemeCloud: clients.terminalThemeCloud,
            terminalAccessoryHandler: TerminalAccessoryPendingMutationHandler(
                cloud: clients.terminalAccessoryCloud,
                resolutionPublisher: terminalAccessoryResolutions
            ),
            statsPreferencesHandler: StatsPreferencesPendingMutationHandler(
                cloud: clients.statsPreferencesCloud,
                resolutionPublisher: statsPreferencesResolutions
            )
        )
        return CloudKitSyncComposition(
            coordinator: CloudKitSyncCoordinator(
                mutationHandler: mutationHandler,
                queue: queue,
                isSyncEnabled: isSyncEnabled,
                currentGeneration: currentGeneration,
                now: now,
                makeID: makeID
            ),
            terminalAccessoryResolutions: terminalAccessoryResolutions,
            statsPreferencesResolutions: statsPreferencesResolutions
        )
    }

    static func makeLive(
        transport: any CloudKitRecordChangeTransport,
        defaults: UserDefaults,
        now: @escaping () -> Date,
        makeID: @escaping () -> UUID
    ) -> CloudKitLiveSyncComposition {
        let serverCloud = ServerCloudKitClient(transport: transport, now: now)
        let terminalThemeCloud = TerminalThemeCloudKitClient(transport: transport)
        let terminalAccessoryCloud = TerminalAccessoryCloudKitClient(transport: transport)
        let statsPreferencesCloud = StatsPreferencesCloudKitClient(transport: transport)
        let composition = make(
            clients: CloudKitSyncClients(
                serverCloud: serverCloud,
                terminalThemeCloud: terminalThemeCloud,
                terminalAccessoryCloud: terminalAccessoryCloud,
                statsPreferencesCloud: statsPreferencesCloud
            ),
            queue: PendingCloudKitSyncQueue(
                defaults: defaults,
                legacyMigrator: CloudKitPendingMutationLegacyMigrator()
            ),
            isSyncEnabled: { SyncSettings.isEnabled(in: defaults) },
            currentGeneration: { transport.cloudKitSyncGeneration },
            now: now,
            makeID: makeID
        )
        return CloudKitLiveSyncComposition(
            coordinator: composition.coordinator,
            terminalAccessoryResolutions: composition.terminalAccessoryResolutions,
            statsPreferencesResolutions: composition.statsPreferencesResolutions,
            serverCloud: serverCloud,
            terminalThemeCloud: terminalThemeCloud,
            terminalAccessoryCloud: terminalAccessoryCloud,
            statsPreferencesCloud: statsPreferencesCloud
        )
    }
}
