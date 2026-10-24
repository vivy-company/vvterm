import Foundation
import UserNotifications

/// The single production dependency graph for the application.
@MainActor
struct AppComposition {
    let networkMonitor: NetworkMonitor
    let analyticsTracker: AnalyticsTracker
    let ghosttyApp: GhosttyRuntime
    let terminalNotificationNavigation: TerminalNotificationNavigationStore
    let storeManager: StoreManager
    let appLockManager: AppLockManager
    let serverManager: ServerManager
    let serverWakeCoordinator: ServerWakeCoordinator
    let engagementTracker: EngagementTracker
    let tabManager: TerminalTabManager
    let remoteFileBrowserStore: RemoteFileBrowserStore
    let terminalFontStore: TerminalFontStore
    let terminalThemeManager: TerminalThemeManager
    let terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    #if os(iOS)
    let terminalFloatingControlPreferencesStore: TerminalFloatingControlPreferencesStore
    #endif
    let statsPreferencesStore: PreferencesStore
    let serverVolumeVisibilityStore: ServerVolumeVisibilityStore
    #if os(macOS)
    let workspaceSelectionStore: WorkspaceSelectionStore
    #endif
    let voiceInputRuntimeStore: VoiceInputRuntimeStore
    let viewTabConfigurationManager: ViewTabConfigurationManager
    let cloudDataSyncCoordinator: AppCloudDataSyncCoordinator
    let syncSettingsCoordinator: SyncSettingsCoordinator
    let sshKeySettingsCoordinator: SSHKeySettingsCoordinator
    let knownHostSettingsCoordinator: KnownHostSettingsCoordinator
    let onWelcomeCompleted: @MainActor () -> Void
    let statsRuntimeStore: ServerStatsRuntimeStore
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    let serverFormDependencies: ServerFormDependencies
    let voiceModelManagers: VoiceSettingsModelManagerOwner
    let statsSecurityApprovalActions: ServerStatsSecurityApprovalActions
    let terminalSecurityActions: TerminalSecurityActions
    let analyticsOptOutAction: AnalyticsOptOutAction
    let appLifecycleDependencies: AppLifecycleDependencies
    #if os(macOS)
    let aboutWindowPresenter: AboutWindowPresenter
    let settingsWindowPresenter: SettingsWindowPresenter
    #endif

    static func live() -> Self {
        Self.init()
    }

    private init() {
        let defaults = UserDefaults.standard
        TerminalDefaults.applyIfNeeded(defaults: defaults)
        #if os(macOS)
        let terminalOptionAsAltMode = defaults.string(
            forKey: TerminalDefaults.optionAsAltModeKey
        ) ?? TerminalOptionAsAltMode.none.rawValue
        #else
        let terminalOptionAsAltMode = TerminalOptionAsAltMode.none.rawValue
        #endif
        let terminalContentPadding = TerminalDefaults.storedContentPadding(defaults: defaults)
        let notificationCenter = NotificationCenter.default
        let calendar = Calendar.current
        let now: @Sendable () -> Date = Date.init
        let makeID: @Sendable () -> UUID = UUID.init
        let defaultWorkspaceName: () -> String = {
            AppLanguage.localizedString(
                "My Servers",
                rawValue: defaults.string(forKey: AppLanguage.storageKey)
            )
        }
        let networkMonitor = NetworkMonitor.shared
        let analyticsTracker = AnalyticsTracker.shared
        let cloudKitManager = CloudKitManager.shared
        let keychainManager = KeychainManager.shared
        let knownHostsManager = KnownHostsManager.shared
        let liveActivityManager = LiveActivityManager.shared
        let remoteMosh = RemoteMoshManager.shared
        let teleportSessionCleanup = TeleportSessionCleanupRelay()
        let teleportAccess = TeleportAccessService(
            keychain: KeychainStore(
                service: (Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm") + ".teleport.identity"
            ),
            makeBrowserSession: { anchor, onCancel in
                TeleportAuthenticationBrowserSession(anchor: anchor, onCancel: onCancel)
            },
            didSignOut: { profileID in
                teleportSessionCleanup.disconnect(profileID: profileID)
            }
        )
        let sshClientFactory = SSHClientLiveComposition.makeFactory(
            defaults: defaults,
            knownHostsManager: knownHostsManager,
            remoteMoshManager: remoteMosh,
            prepareConnection: { request in
                try await teleportAccess.prepare(request)
            }
        )
        let connectionOperations = SSHConnectionOperationService(
            clientFactory: sshClientFactory
        )
        let remoteTmux = RemoteTmuxManager()
        let remoteSessions = RemoteSessionClient(
            registry: RemoteSessionBackendRegistry(backends: [
                HerdrRemoteSessionBackend(),
                TmuxRemoteSessionBackend(tmux: remoteTmux),
                ZellijRemoteSessionBackend(),
                ZmxRemoteSessionBackend()
            ])
        )
        let eternalTerminalResumeStore = EternalTerminalResumeStore.shared
        let moshResumeStore = MoshResumeStore.shared
        let terminalSurfaceStore = GhosttyTerminalSurfaceStore()
        let deviceID = DeviceIdentity.id
        let platform = AppPlatformComposition.live(
            cloudKitManager: cloudKitManager,
            networkMonitor: networkMonitor,
            liveActivityManager: liveActivityManager
        )
        let applicationIsActive = platform.applicationIsActive
        let appLockManager = AppLockManager()
        let syncLifecycle = CloudKitSyncLifecycleDriver(
            defaults: defaults,
            notificationCenter: notificationCenter,
            now: now
        )
        let isSyncEnabled = { SyncSettings.isEnabled(in: defaults) }
        let terminalFontRepository = LocalTerminalFontRepository.applicationSupport(
            defaults: defaults
        )
        let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
            transport: cloudKitManager,
            terminalFontRepository: terminalFontRepository,
            defaults: defaults,
            now: now,
            makeID: makeID
        )
        let cloudKitSyncCoordinator = cloudKitSync.coordinator
        let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory = {
            LocalSSHDiscoveryManager(
                dependencies: .live(
                    networkConnectionType: { networkMonitor.connectionType },
                    makeScanID: makeID
                )
            )
        }
        let serverDeletionTerminalCleanup = ServerDeletionTerminalCleanupRelay()
        let serverManager = ServerManager(
            dependencies: .live(
                defaults: defaults,
                serverCloud: cloudKitSync.serverCloud,
                credentialRepository: keychainManager,
                knownHosts: knownHostsManager,
                freePlanTracker: analyticsTracker,
                actionAuthorizer: appLockManager,
                syncRepository: cloudKitSyncCoordinator,
                didDeleteServerLocalData: { serverID in
                    serverDeletionTerminalCleanup.handleServerDeletion(serverID)
                },
                defaultWorkspaceName: defaultWorkspaceName,
                now: now,
                makeID: makeID
            )
        )
        let serverWakeCoordinator = ServerWakeCoordinator(
            dependencies: ServerWakeDependencies(
                sender: BSDWakeOnLANPacketSender(
                    interfaceProvider: SystemWakeOnLANInterfaceProvider(),
                    datagramSender: BSDWakeOnLANDatagramSender()
                ),
                macAddressResolver: SSHServerWakeOnLANMACAddressResolver(
                    connectionOperations: connectionOperations
                ),
                mutations: serverManager,
                credentials: keychainManager,
                makeID: makeID
            )
        )
        let serverFormDependencies = ServerFormDependencies.live(
            credentials: keychainManager,
            hostKeys: knownHostsManager,
            connectionOperations: connectionOperations,
            remoteMosh: remoteMosh,
            remoteSessionBackends: remoteSessions.backendMetadata,
            defaultRemoteSessionEnabled: {
                defaults.object(forKey: TerminalRemoteSessionDefaults.enabledKey) == nil
                    ? true
                    : defaults.bool(forKey: TerminalRemoteSessionDefaults.enabledKey)
            },
            defaultRemoteSessionBackendIdentifier: {
                let stored = defaults.string(
                    forKey: TerminalRemoteSessionDefaults.backendIdentifierKey
                ).map(RemoteSessionBackendIdentifier.init(rawValue:))
                return remoteSessions.backendMetadata.contains { $0.identifier == stored }
                    ? stored ?? .tmux
                    : .tmux
            },
            defaultRemoteSessionStartupBehavior: {
                defaults.string(forKey: TerminalRemoteSessionDefaults.startupBehaviorKey)
                    .flatMap(RemoteSessionStartupBehavior.init(persistedRawValue:)) ?? .ask
            },
            now: now,
            makeID: makeID,
            teleportAccess: teleportAccess
        )
        let engagementTracker = EngagementTracker(
            dependencies: .live(
                defaults: defaults,
                analytics: analyticsTracker,
                now: now,
                calendar: calendar,
                applicationIsActive: applicationIsActive
            )
        )
        let terminalFontStore = TerminalFontStore(
            dependencies: .live(
                repository: terminalFontRepository,
                cloud: cloudKitSync.terminalFontCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                isSyncEnabled: isSyncEnabled,
                now: now
            )
        )
        let terminalThemeManager = TerminalThemeManager(
            dependencies: .live(
                defaults: defaults,
                notificationCenter: notificationCenter,
                cloud: cloudKitSync.terminalThemeCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                themeFiles: TerminalThemeFileStore.appStorage,
                builtInThemeCatalog: BundleTerminalThemeCatalog(),
                paletteResolver: ThemeColorParserPaletteResolver(),
                isSyncEnabled: isSyncEnabled,
                now: now
            )
        )
        let tabManager = TerminalTabManagerLiveComposition.makeManager(
            defaults: defaults,
            sshClientFactory: sshClientFactory,
            networkMonitor: networkMonitor,
            appLockManager: appLockManager,
            serverManager: serverManager,
            prepareInitialConnection: { server in
                serverWakeCoordinator.startAutomaticallyIfEnabled(for: server)
            },
            engagementTracker: engagementTracker,
            analyticsTracker: analyticsTracker,
            liveActivityManager: liveActivityManager,
            remoteMosh: remoteMosh,
            remoteSessions: remoteSessions,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshResumeStore: moshResumeStore,
            terminalSurfaceStore: terminalSurfaceStore,
            deviceID: deviceID,
            themeStyle: {
                TerminalRemoteSessionLiveComposition.themeStyle(
                    for: terminalThemeManager.themeSelection.darkThemeName
                )
            },
            applicationIsActive: applicationIsActive
        )
        serverDeletionTerminalCleanup.bind(to: tabManager)
        teleportSessionCleanup.servers = serverManager
        teleportSessionCleanup.tabs = tabManager
        let storeManager = StoreManager(
            client: AppStoreKitClient(),
            effects: .live(
                analytics: analyticsTracker,
                engagementTracker: engagementTracker
            )
        )
        let terminalAccessoryPreferencesManager = TerminalAccessoryPreferencesManager(
            dependencies: .live(
                defaults: defaults,
                cloud: cloudKitSync.terminalAccessoryCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                resolutionSource: cloudKitSync.terminalAccessoryResolutions,
                writerID: deviceID,
                isSyncEnabled: isSyncEnabled,
                now: now,
                makeID: makeID,
                trackCustomActionCreated: { kind in
                    analyticsTracker.trackCustomActionCreated(kind: kind.rawValue)
                }
            )
        )
        #if os(iOS)
        let terminalFloatingControlPreferencesStore = TerminalFloatingControlPreferencesStore(
            repository: UserDefaultsTerminalFloatingControlPreferencesRepository(
                defaults: defaults
            )
        )
        #endif
        let statsPreferencesStore = PreferencesStore(
            dependencies: .live(
                defaults: defaults,
                cloud: cloudKitSync.statsPreferencesCloud,
                mutationQueue: cloudKitSyncCoordinator,
                syncLifecycle: syncLifecycle,
                resolutionSource: cloudKitSync.statsPreferencesResolutions,
                writerID: deviceID,
                isSyncEnabled: isSyncEnabled,
                now: now
            )
        )
        let serverVolumeVisibilityStore = ServerVolumeVisibilityStore.live
        #if os(macOS)
        let workspaceSelectionStore = WorkspaceSelectionLiveComposition.makeStore(
            defaults: defaults
        )
        #endif
        let viewTabConfigurationManager = ViewTabConfigurationManager(defaults: defaults)
        let voiceSettingsPersistence = UserDefaultsVoiceSettingsPersistence(defaults: defaults)
        let voiceSettingsStore = VoiceSettingsStore(persistence: voiceSettingsPersistence)
        let voiceModelManagers = VoiceSettingsModelManagerOwner(
            settingsStore: voiceSettingsStore,
            makeManager: { kind, selectedModelID in
                MLXModelManager(
                    kind: kind,
                    selectedModelID: selectedModelID,
                    storageRoot: MLXModelManager.modelsRoot,
                    sessionLifecycle: .live,
                    operations: .live
                )
            }
        )
        let voiceInputRuntimeStore = VoiceInputRuntimeStore(
            settingsStore: voiceSettingsStore,
            makeRuntime: VoiceInputRuntimeLiveComposition.makeFactory(
                settingsStore: voiceSettingsStore
            )
        )
        let makeStatsCollector = Self.makeStatsCollectorFactory(
            keychainManager: keychainManager,
            knownHostsManager: knownHostsManager,
            connectionOperations: connectionOperations,
            sshClientFactory: sshClientFactory
        )
        let statsRuntimeStore = ServerStatsRuntimeStore(
            makeCollector: makeStatsCollector
        )
        let terminalSecurityActions = Self.makeTerminalSecurityActions(
            keychainManager: keychainManager,
            knownHostsManager: knownHostsManager
        )
        let analyticsOptOutAction = AnalyticsOptOutAction(
            emitAnalyticsDisabled: {
                analyticsTracker.trackAnalyticsDisabled()
            }
        )
        let onWelcomeCompleted: @MainActor () -> Void = {
            analyticsTracker.trackWelcomeCompleted()
        }
        let cloudDataSyncCoordinator = AppCloudDataSyncCoordinator(
            isEnabled: { SyncSettings.isEnabled(in: defaults) },
            steps: [
                { await cloudKitSyncCoordinator.drainPendingMutations() },
                {
                    await serverManager.refreshCloudData()
                    guard serverManager.stateStore.ambiguousCloudRecovery == nil,
                          serverManager.stateStore.error == nil else {
                        throw AppCloudDataSyncError.serverData
                    }
                },
                { try await terminalThemeManager.refreshFromCloud() },
                { try await terminalFontStore.refreshFromCloud() },
                { try await terminalAccessoryPreferencesManager.refreshFromCloud() },
                { try await statsPreferencesStore.refreshFromCloud() },
                { await cloudKitSyncCoordinator.drainPendingMutations() }
            ]
        )
        let syncSettingsCoordinator = SyncSettingsLiveComposition.makeCoordinator(
            refreshCloudData: cloudDataSyncCoordinator.refresh,
            cancelCloudDataRefresh: cloudDataSyncCoordinator.cancel,
            cloudKit: cloudKitManager,
            keychain: keychainManager,
            serverManager: serverManager,
            terminalTheme: terminalThemeManager,
            terminalFont: terminalFontStore,
            pendingSync: cloudKitSyncCoordinator,
            defaults: defaults
        )
        let sshKeySettingsCoordinator = SSHKeySettingsLiveComposition.makeCoordinator(
            keychain: keychainManager
        )
        let knownHostSettingsCoordinator = KnownHostSettingsLiveComposition.makeCoordinator(
            knownHosts: knownHostsManager
        )
        let appLifecycleDependencies = platform.lifecycleDependencies
        let ghosttyRuntimeConfiguration = Ghostty.RuntimeConfiguration(
            fontSelection: TerminalFontSelectionPolicy.resolve(
                primaryFamily: terminalFontStore.preference.primaryFamily,
                cjkFamily: terminalFontStore.preference.cjkFamily,
                catalog: terminalFontStore.catalog,
                allowsProFeatures: true
            ),
            fontSize: defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double
                ?? TerminalDefaults.defaultFontSize,
            contentPadding: terminalContentPadding,
            cursorStyleRawValue: defaults.string(forKey: TerminalDefaults.cursorStyleKey)
                ?? TerminalDefaults.defaultCursorStyle.rawValue,
            cursorBlink: defaults.object(forKey: TerminalDefaults.cursorBlinkKey) as? Bool
                ?? TerminalDefaults.defaultCursorBlink,
            optionAsAltModeRawValue: terminalOptionAsAltMode,
            remoteClipboardPolicyRawValue: defaults.string(
                forKey: TerminalRemoteClipboardPolicy.userDefaultsKey
            ) ?? TerminalRemoteClipboardPolicy.defaultValue.rawValue
        )
        let terminalNotificationNavigation = TerminalNotificationNavigationStore(
            tabManager: tabManager,
            serverProvider: { id in serverManager.servers.first { $0.id == id } },
            unlockServer: { server in await appLockManager.ensureServerUnlocked(server) }
        )
        let ghosttyApp = GhosttyRuntime(
            configuration: ghosttyRuntimeConfiguration,
            notificationClient: NativeTerminalNotificationClient(
                center: .current(), defaults: defaults, onOpen: terminalNotificationNavigation.request
            ),
            autoStart: false
        )
        let statsSecurityApprovalActions = Self.makeStatsSecurityApprovalActions(
            knownHostsManager: knownHostsManager
        )
        let remoteFileBrowserStore = Self.makeRemoteFileBrowserStore(
            tabManager: tabManager,
            serverManager: serverManager,
            credentialRepository: keychainManager,
            connectionOperations: connectionOperations,
            clientFactory: sshClientFactory,
            securityApprovalActions: Self.makeRemoteFileSecurityApprovalActions(
                knownHostsManager: knownHostsManager
            ),
            defaults: defaults
        )
        #if os(macOS)
        let aboutWindowPresenter = AboutWindowPresenter()
        let settingsWindowPresenter = SettingsWindowPresenter(
            appLockManager: appLockManager,
            serverManager: serverManager,
            terminalFontStore: terminalFontStore,
            terminalThemeManager: terminalThemeManager,
            terminalAccessoryPreferencesManager: terminalAccessoryPreferencesManager,
            viewTabConfigurationManager: viewTabConfigurationManager,
            storeManager: storeManager,
            statsPreferencesStore: statsPreferencesStore,
            syncSettingsCoordinator: syncSettingsCoordinator,
            sshKeySettingsCoordinator: sshKeySettingsCoordinator,
            knownHostSettingsCoordinator: knownHostSettingsCoordinator,
            voiceModelManagers: voiceModelManagers,
            analyticsOptOutAction: analyticsOptOutAction,
            remoteSessionBackends: remoteSessions.backendMetadata,
            ghosttyApp: ghosttyApp
        )
        #endif

        self.networkMonitor = networkMonitor
        self.analyticsTracker = analyticsTracker
        self.ghosttyApp = ghosttyApp
        self.terminalNotificationNavigation = terminalNotificationNavigation
        self.storeManager = storeManager
        self.appLockManager = appLockManager
        self.serverManager = serverManager
        self.serverWakeCoordinator = serverWakeCoordinator
        self.engagementTracker = engagementTracker
        self.tabManager = tabManager
        self.remoteFileBrowserStore = remoteFileBrowserStore
        self.terminalFontStore = terminalFontStore
        self.terminalThemeManager = terminalThemeManager
        self.terminalAccessoryPreferencesManager = terminalAccessoryPreferencesManager
        #if os(iOS)
        self.terminalFloatingControlPreferencesStore = terminalFloatingControlPreferencesStore
        #endif
        self.statsPreferencesStore = statsPreferencesStore
        self.serverVolumeVisibilityStore = serverVolumeVisibilityStore
        #if os(macOS)
        self.workspaceSelectionStore = workspaceSelectionStore
        #endif
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.viewTabConfigurationManager = viewTabConfigurationManager
        self.cloudDataSyncCoordinator = cloudDataSyncCoordinator
        self.syncSettingsCoordinator = syncSettingsCoordinator
        self.sshKeySettingsCoordinator = sshKeySettingsCoordinator
        self.knownHostSettingsCoordinator = knownHostSettingsCoordinator
        self.onWelcomeCompleted = onWelcomeCompleted
        self.statsRuntimeStore = statsRuntimeStore
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.serverFormDependencies = serverFormDependencies
        self.voiceModelManagers = voiceModelManagers
        self.statsSecurityApprovalActions = statsSecurityApprovalActions
        self.terminalSecurityActions = terminalSecurityActions
        self.analyticsOptOutAction = analyticsOptOutAction
        self.appLifecycleDependencies = appLifecycleDependencies
        #if os(macOS)
        self.aboutWindowPresenter = aboutWindowPresenter
        self.settingsWindowPresenter = settingsWindowPresenter
        #endif
    }
}
