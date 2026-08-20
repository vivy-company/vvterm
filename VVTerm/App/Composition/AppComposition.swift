import Foundation

/// The single production dependency graph for the application.
@MainActor
struct AppComposition {
    let networkMonitor: NetworkMonitor
    let analyticsTracker: AnalyticsTracker
    let ghosttyApp: GhosttyRuntime
    let storeManager: StoreManager
    let appLockManager: AppLockManager
    let serverManager: ServerManager
    let engagementTracker: EngagementTracker
    let tabManager: TerminalTabManager
    let remoteFileBrowserStore: RemoteFileBrowserStore
    let terminalThemeManager: TerminalThemeManager
    let terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    let statsPreferencesStore: PreferencesStore
    let serverVolumeVisibilityStore: ServerVolumeVisibilityStore
    #if os(macOS)
    let workspaceSelectionStore: WorkspaceSelectionStore
    #endif
    let voiceInputRuntimeStore: VoiceInputRuntimeStore
    let viewTabConfigurationManager: ViewTabConfigurationManager
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
        let ghosttyRuntimeConfiguration = Ghostty.RuntimeConfiguration(
            fontName: defaults.string(forKey: TerminalDefaults.fontNameKey)
                ?? TerminalDefaults.defaultFontName,
            fontSize: defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double
                ?? TerminalDefaults.defaultFontSize,
            cursorStyleRawValue: defaults.string(forKey: TerminalDefaults.cursorStyleKey)
                ?? TerminalDefaults.defaultCursorStyle.rawValue,
            cursorBlink: defaults.object(forKey: TerminalDefaults.cursorBlinkKey) as? Bool
                ?? TerminalDefaults.defaultCursorBlink,
            optionAsAltModeRawValue: terminalOptionAsAltMode,
            remoteClipboardReadPolicyRawValue: defaults.string(
                forKey: TerminalRemoteClipboardReadPolicy.userDefaultsKey
            ) ?? TerminalRemoteClipboardReadPolicy.defaultValue.rawValue
        )
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
        let canonicalDefaultWorkspaceNames: () -> Set<String> = {
            AppLanguage.localizedValues(for: "My Servers")
        }
        let networkMonitor = NetworkMonitor.shared
        let analyticsTracker = AnalyticsTracker.shared
        let cloudKitManager = CloudKitManager.shared
        let keychainManager = KeychainManager.shared
        let knownHostsManager = KnownHostsManager.shared
        let liveActivityManager = LiveActivityManager.shared
        let remoteMosh = RemoteMoshManager.shared
        let sshClientFactory = SSHClientLiveComposition.makeFactory(
            defaults: defaults,
            knownHostsManager: knownHostsManager,
            remoteMoshManager: remoteMosh
        )
        let connectionOperations = SSHConnectionOperationService(
            clientFactory: sshClientFactory
        )
        let remoteTmux = RemoteTmuxManager.shared
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
        let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
            transport: cloudKitManager,
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
        let serverManager = ServerManager(
            dependencies: .live(
                defaults: defaults,
                serverCloud: cloudKitSync.serverCloud,
                credentialRepository: keychainManager,
                knownHosts: knownHostsManager,
                freePlanTracker: analyticsTracker,
                actionAuthorizer: appLockManager,
                syncRepository: cloudKitSyncCoordinator,
                defaultWorkspaceName: defaultWorkspaceName,
                canonicalDefaultWorkspaceNames: canonicalDefaultWorkspaceNames,
                now: now,
                makeID: makeID
            )
        )
        let serverFormDependencies = ServerFormDependencies.live(
            credentials: keychainManager,
            hostKeys: knownHostsManager,
            connectionOperations: connectionOperations,
            remoteMosh: remoteMosh,
            defaultTmuxEnabled: {
                defaults.object(forKey: "terminalTmuxEnabledDefault") == nil
                    ? true
                    : defaults.bool(forKey: "terminalTmuxEnabledDefault")
            },
            defaultTmuxStartupBehavior: {
                defaults.string(forKey: "terminalTmuxStartupBehaviorDefault")
                    .flatMap(TmuxStartupBehavior.init(rawValue:)) ?? .askEveryTime
            },
            now: now,
            makeID: makeID
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
            engagementTracker: engagementTracker,
            analyticsTracker: analyticsTracker,
            liveActivityManager: liveActivityManager,
            remoteMosh: remoteMosh,
            remoteTmux: remoteTmux,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshResumeStore: moshResumeStore,
            terminalSurfaceStore: terminalSurfaceStore,
            deviceID: deviceID,
            themeStyle: {
                TerminalTmuxSessionLiveComposition.themeStyle(
                    for: terminalThemeManager.themeSelection.darkThemeName
                )
            },
            applicationIsActive: applicationIsActive
        )
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
        let syncSettingsCoordinator = SyncSettingsLiveComposition.makeCoordinator(
            cloudKit: cloudKitManager,
            keychain: keychainManager,
            serverManager: serverManager,
            terminalTheme: terminalThemeManager,
            terminalAccessory: terminalAccessoryPreferencesManager,
            statsPreferences: statsPreferencesStore,
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
        let ghosttyApp = GhosttyRuntime(
            configuration: ghosttyRuntimeConfiguration,
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
            terminalThemeManager: terminalThemeManager,
            terminalAccessoryPreferencesManager: terminalAccessoryPreferencesManager,
            viewTabConfigurationManager: viewTabConfigurationManager,
            storeManager: storeManager,
            statsPreferencesStore: statsPreferencesStore,
            syncSettingsCoordinator: syncSettingsCoordinator,
            sshKeySettingsCoordinator: sshKeySettingsCoordinator,
            knownHostSettingsCoordinator: knownHostSettingsCoordinator,
            voiceModelManagers: voiceModelManagers,
            analyticsOptOutAction: analyticsOptOutAction
        )
        #endif

        self.networkMonitor = networkMonitor
        self.analyticsTracker = analyticsTracker
        self.ghosttyApp = ghosttyApp
        self.storeManager = storeManager
        self.appLockManager = appLockManager
        self.serverManager = serverManager
        self.engagementTracker = engagementTracker
        self.tabManager = tabManager
        self.remoteFileBrowserStore = remoteFileBrowserStore
        self.terminalThemeManager = terminalThemeManager
        self.terminalAccessoryPreferencesManager = terminalAccessoryPreferencesManager
        self.statsPreferencesStore = statsPreferencesStore
        self.serverVolumeVisibilityStore = serverVolumeVisibilityStore
        #if os(macOS)
        self.workspaceSelectionStore = workspaceSelectionStore
        #endif
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.viewTabConfigurationManager = viewTabConfigurationManager
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
