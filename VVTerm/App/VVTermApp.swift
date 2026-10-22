//
//  VVTermApp.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
#endif

@main
struct VVTermApp: App {
    init() {
        let composition = AppComposition.live()
        networkMonitor = composition.networkMonitor
        tabManager = composition.tabManager
        voiceInputRuntimeStore = composition.voiceInputRuntimeStore
        statsRuntimeStore = composition.statsRuntimeStore
        makeLocalDiscoveryManager = composition.makeLocalDiscoveryManager
        serverFormDependencies = composition.serverFormDependencies
        voiceModelManagers = composition.voiceModelManagers
        statsSecurityApprovalActions = composition.statsSecurityApprovalActions
        terminalSecurityActions = composition.terminalSecurityActions
        onWelcomeCompleted = composition.onWelcomeCompleted
        _ghosttyApp = StateObject(wrappedValue: composition.ghosttyApp)
        _terminalNotificationNavigation = StateObject(wrappedValue: composition.terminalNotificationNavigation)
        _storeManager = StateObject(wrappedValue: composition.storeManager)
        _appLockManager = StateObject(wrappedValue: composition.appLockManager)
        _serverManager = StateObject(wrappedValue: composition.serverManager)
        _serverWakeCoordinator = StateObject(
            wrappedValue: composition.serverWakeCoordinator
        )
        _engagementTracker = StateObject(wrappedValue: composition.engagementTracker)
        _remoteFileBrowserStore = StateObject(wrappedValue: composition.remoteFileBrowserStore)
        _terminalFontStore = StateObject(
            wrappedValue: composition.terminalFontStore
        )
        _terminalThemeManager = StateObject(wrappedValue: composition.terminalThemeManager)
        _terminalAccessoryPreferencesManager = StateObject(
            wrappedValue: composition.terminalAccessoryPreferencesManager
        )
        #if os(iOS)
        _terminalFloatingControlPreferencesStore = StateObject(
            wrappedValue: composition.terminalFloatingControlPreferencesStore
        )
        #endif
        _statsPreferencesStore = StateObject(wrappedValue: composition.statsPreferencesStore)
        _serverVolumeVisibilityStore = StateObject(
            wrappedValue: composition.serverVolumeVisibilityStore
        )
        _viewTabConfigurationManager = StateObject(
            wrappedValue: composition.viewTabConfigurationManager
        )
        _syncSettingsCoordinator = StateObject(wrappedValue: composition.syncSettingsCoordinator)
        _sshKeySettingsCoordinator = StateObject(
            wrappedValue: composition.sshKeySettingsCoordinator
        )
        _knownHostSettingsCoordinator = StateObject(
            wrappedValue: composition.knownHostSettingsCoordinator
        )
        #if os(iOS)
        analyticsOptOutAction = composition.analyticsOptOutAction
        #else
        _workspaceSelectionStore = StateObject(wrappedValue: composition.workspaceSelectionStore)
        aboutWindowPresenter = composition.aboutWindowPresenter
        settingsWindowPresenter = composition.settingsWindowPresenter
        #endif

        appDelegate.configure(
            tabManager: composition.tabManager,
            cloudDataSync: composition.cloudDataSyncCoordinator,
            appLockManager: composition.appLockManager,
            lifecycleDependencies: composition.appLifecycleDependencies
        )
        #if os(macOS)
        MacConnectionToolbarController.shared.configure(tabManager: composition.tabManager)
        #endif
        composition.storeManager.start()

        #if os(iOS)
        VVTermLauncherWidgetRefresh.refreshIfNeeded()
        composition.analyticsTracker.prepareAppleAdsAttribution()
        #endif
    }

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @StateObject private var ghosttyApp: GhosttyRuntime
    @StateObject private var terminalNotificationNavigation: TerminalNotificationNavigationStore
    #if os(iOS)
    @StateObject private var screenAwakeCoordinator = TerminalScreenAwakeCoordinator()
    private let analyticsOptOutAction: AnalyticsOptOutAction
    #endif
    @StateObject private var appLockManager: AppLockManager
    @StateObject private var serverManager: ServerManager
    @StateObject private var serverWakeCoordinator: ServerWakeCoordinator
    @StateObject private var engagementTracker: EngagementTracker
    private let networkMonitor: NetworkMonitor
    private let tabManager: TerminalTabManager
    @StateObject private var storeManager: StoreManager
    @StateObject private var remoteFileTabManager = RemoteFileTabManager()
    @StateObject private var remoteFileBrowserStore: RemoteFileBrowserStore
    @StateObject private var terminalFontStore: TerminalFontStore
    @StateObject private var terminalThemeManager: TerminalThemeManager
    @StateObject private var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    #if os(iOS)
    @StateObject private var terminalFloatingControlPreferencesStore:
        TerminalFloatingControlPreferencesStore
    #endif
    @StateObject private var statsPreferencesStore: PreferencesStore
    @StateObject private var serverVolumeVisibilityStore: ServerVolumeVisibilityStore
    #if os(macOS)
    @StateObject private var workspaceSelectionStore: WorkspaceSelectionStore
    #endif
    private let voiceInputRuntimeStore: VoiceInputRuntimeStore
    @StateObject private var viewTabConfigurationManager: ViewTabConfigurationManager
    @StateObject private var syncSettingsCoordinator: SyncSettingsCoordinator
    @StateObject private var sshKeySettingsCoordinator: SSHKeySettingsCoordinator
    @StateObject private var knownHostSettingsCoordinator: KnownHostSettingsCoordinator
    private let onWelcomeCompleted: @MainActor () -> Void
    private let statsRuntimeStore: ServerStatsRuntimeStore
    private let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    private let serverFormDependencies: ServerFormDependencies
    private let voiceModelManagers: VoiceSettingsModelManagerOwner
    private let statsSecurityApprovalActions: ServerStatsSecurityApprovalActions
    private let terminalSecurityActions: TerminalSecurityActions
    #if os(macOS)
    private let aboutWindowPresenter: AboutWindowPresenter
    private let settingsWindowPresenter: SettingsWindowPresenter
    #endif

    // Welcome screen flag
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    // App language
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false

    // Terminal settings to watch for changes
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.contentPaddingHorizontalKey)
    private var terminalContentPaddingHorizontal = TerminalDefaults.defaultContentPadding
    @AppStorage(TerminalDefaults.contentPaddingVerticalKey)
    private var terminalContentPaddingVertical = TerminalDefaults.defaultContentPadding
    @AppStorage(TerminalDefaults.cursorStyleKey) private var terminalCursorStyle = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var terminalCursorBlink = TerminalDefaults.defaultCursorBlink
    #if os(macOS)
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var terminalOptionAsAltMode = TerminalOptionAsAltMode.none.rawValue
    #endif
    @AppStorage(TerminalRemoteClipboardPolicy.userDefaultsKey)
    private var remoteClipboardPolicy = TerminalRemoteClipboardPolicy.defaultValue.rawValue

    private var terminalOptionAsAltModeRawValue: String {
        #if os(macOS)
        terminalOptionAsAltMode
        #else
        TerminalOptionAsAltMode.none.rawValue
        #endif
    }

    private var ghosttyRuntimeConfiguration: Ghostty.RuntimeConfiguration {
        Ghostty.RuntimeConfiguration(
            fontSelection: TerminalFontSelectionPolicy.resolve(
                primaryFamily: terminalFontStore.preference.primaryFamily,
                cjkFamily: terminalFontStore.preference.cjkFamily,
                catalog: terminalFontStore.catalog,
                allowsProFeatures: storeManager.allowsProFeatures
            ),
            fontSize: terminalFontSize,
            contentPadding: TerminalContentPadding(
                horizontal: terminalContentPaddingHorizontal,
                vertical: terminalContentPaddingVertical
            ),
            cursorStyleRawValue: terminalCursorStyle,
            cursorBlink: terminalCursorBlink,
            optionAsAltModeRawValue: terminalOptionAsAltModeRawValue,
            remoteClipboardPolicyRawValue: remoteClipboardPolicy
        )
    }

    private var statsDependencies: ServerStatsScreenDependencies {
        ServerStatsScreenDependencies(
            runtimeStore: statsRuntimeStore,
            preferencesStore: statsPreferencesStore,
            volumeVisibilityStore: serverVolumeVisibilityStore,
            securityApprovalActions: statsSecurityApprovalActions
        )
    }

    #if DEBUG
    private var usesSyncSettingsUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-sync-settings-harness"
        )
    }

    private var usesTrustedHostsSettingsUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-trusted-hosts-settings-harness"
        )
    }

    private var usesServerDuplicateUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-server-duplicate-harness"
        )
    }
    #endif

    #if os(iOS) && DEBUG
    private var usesTerminalKeyboardUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-keyboard-harness")
    }

    private var usesTerminalSplitKeyboardUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-terminal-split-keyboard-harness"
        )
    }

    private var usesTerminalReconnectUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-reconnect-harness")
    }

    private var usesTerminalScreenAwakeUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-screen-awake-harness")
    }

    private var usesNoticePresentationUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notice-harness")
    }

    private var usesStatsStorageUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-storage-harness")
    }

    private var usesStatsCardsLayoutUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-cards-layout-harness")
    }

    private var usesTerminalZenModeUITestHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-zen-mode-harness")
    }
    #endif

    #if os(macOS)
    @ViewBuilder
    private var macOSRootContent: some View {
        #if DEBUG
        if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-custom-theme-duplicate") {
            CustomThemeDuplicateUITestHarness()
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notification-settings") {
            TerminalNotificationSettingsUITestHarness()
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-events") {
            TerminalEventsUITestHarness(tabManager: tabManager)
        } else if usesSyncSettingsUITestHarness {
            SyncSettingsUITestHarness()
        } else if usesTrustedHostsSettingsUITestHarness {
            TrustedHostsSettingsUITestHarness()
        } else if usesServerDuplicateUITestHarness {
            ServerDuplicateUITestHarness(
                serverManager: serverManager,
                dependencies: serverFormDependencies,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager
            )
        } else if Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-mac-terminal-recovery-harness"
        ) {
            MacTerminalRecoveryUITestHarness(
                simulatesSuccess: !Foundation.ProcessInfo.processInfo.arguments.contains(
                    "--vvterm-ui-test-mac-terminal-recovery-failure"
                )
            )
        } else {
            macOSAppContent
        }
        #else
        macOSAppContent
        #endif
    }

    private var macOSAppContent: some View {
        ContentView(
            serverManager: serverManager,
            serverWakeCoordinator: serverWakeCoordinator,
            engagementTracker: engagementTracker,
            tabManager: tabManager,
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore,
            statsDependencies: statsDependencies,
            terminalSecurityActions: terminalSecurityActions,
            serverFormDependencies: serverFormDependencies,
            workspaceSelectionStore: workspaceSelectionStore,
            voiceInputRuntimeStore: voiceInputRuntimeStore,
            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
            onOpenSettings: { settingsWindowPresenter.show() }
        )
            .environmentObject(ghosttyApp)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
            .modifier(AppearanceModifier())
            .task(id: ghosttyRuntimeConfiguration) {
                ghosttyApp.applyConfiguration(ghosttyRuntimeConfiguration)
            }
            .sheet(isPresented: .init(
                get: { !hasSeenWelcome },
                set: { if !$0 { hasSeenWelcome = true } }
            )) {
                WelcomeView(
                    hasSeenWelcome: $hasSeenWelcome,
                    onCompleted: onWelcomeCompleted
                )
                    .adaptiveSoftScrollEdges()
            }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var iOSRootContent: some View {
        #if DEBUG
        if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-stats-collection") {
            StatsCollectionUITestHarness()
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-composer") {
            TerminalComposerUITestHarness(keyboard: tabManager.keyboardCoordinator)
                .environmentObject(ghosttyApp)
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-connection-sign-in") {
            TeleportConnectionSignInUITestHarness()
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-custom-theme-duplicate") {
            CustomThemeDuplicateUITestHarness()
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-notification-settings") {
            TerminalNotificationSettingsUITestHarness()
        } else if Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-events") {
            TerminalEventsUITestHarness(tabManager: tabManager)
        } else if usesSyncSettingsUITestHarness {
            SyncSettingsUITestHarness()
        } else if usesTrustedHostsSettingsUITestHarness {
            TrustedHostsSettingsUITestHarness()
        } else if usesServerDuplicateUITestHarness {
            ServerDuplicateUITestHarness(
                serverManager: serverManager,
                dependencies: serverFormDependencies,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager
            )
        } else if usesNoticePresentationUITestHarness {
            NoticePresentationUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesStatsCardsLayoutUITestHarness {
            StatsCardsLayoutUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalZenModeUITestHarness {
            TerminalZenModeUITestHarness(
                tabManager: tabManager,
                voiceInputRuntimeStore: voiceInputRuntimeStore
            )
                .environmentObject(ghosttyApp)
                .modifier(AppearanceModifier())
        } else if usesStatsStorageUITestHarness {
            StatsStorageUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalScreenAwakeUITestHarness {
            TerminalScreenAwakeUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalReconnectUITestHarness {
            TerminalReconnectUITestHarness(
                tabManager: tabManager,
                serverManager: serverManager,
                serverWakeCoordinator: serverWakeCoordinator,
                fileBrowser: remoteFileBrowserStore,
                engagementTracker: engagementTracker,
                statsDependencies: statsDependencies,
                terminalSecurityActions: terminalSecurityActions,
                serverFormDependencies: serverFormDependencies,
                voiceModelManagers: voiceModelManagers,
                voiceInputRuntimeStore: voiceInputRuntimeStore,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager
            )
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else if usesTerminalSplitKeyboardUITestHarness {
            TerminalSplitKeyboardUITestHarness(tabManager: tabManager)
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else if usesTerminalKeyboardUITestHarness {
            TerminalKeyboardUITestHarness(
                tabManager: tabManager,
                voiceInputRuntimeStore: voiceInputRuntimeStore
            )
                .environmentObject(ghosttyApp)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .modifier(AppearanceModifier())
        } else {
            iOSAppContent
        }
        #else
        iOSAppContent
        #endif
    }

    private var iOSAppContent: some View {
        iOSContentView(
            serverManager: serverManager,
            serverWakeCoordinator: serverWakeCoordinator,
            engagementTracker: engagementTracker,
            tabManager: tabManager,
            fileTabs: remoteFileTabManager,
            fileBrowser: remoteFileBrowserStore,
            statsDependencies: statsDependencies,
            terminalSecurityActions: terminalSecurityActions,
            serverFormDependencies: serverFormDependencies,
            voiceModelManagers: voiceModelManagers,
            voiceInputRuntimeStore: voiceInputRuntimeStore,
            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
            analyticsOptOutAction: analyticsOptOutAction
        )
            .environmentObject(ghosttyApp)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
            .modifier(AppearanceModifier())
            .task(id: ghosttyRuntimeConfiguration) {
                ghosttyApp.applyConfiguration(ghosttyRuntimeConfiguration)
            }
            .sheet(isPresented: .init(
                get: { !hasSeenWelcome },
                set: { if !$0 { hasSeenWelcome = true } }
            )) {
                WelcomeView(
                    hasSeenWelcome: $hasSeenWelcome,
                    onCompleted: onWelcomeCompleted
                )
                    .adaptiveSoftScrollEdges()
            }
    }
    #endif

    var body: some Scene {
        WindowGroup("", id: "main") {
            let appLocale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
            AppLockContainer {
                NoticeAppHost(networkMonitor: networkMonitor) {
                    Group {
                        #if os(iOS)
                        iOSRootContent
                            .environmentObject(screenAwakeCoordinator)
                            .environmentObject(terminalFloatingControlPreferencesStore)
                        #else
                        macOSRootContent
                        #endif
                    }
                    .modifier(TeleportConnectionSignInHost(
                        dependencies: serverFormDependencies, serverManager: serverManager
                    ))
                    .adaptiveSoftScrollEdges()
                    .environment(\.locale, appLocale)
                    .environment(\.privacyModeEnabled, privacyModeEnabled)
                    .onAppear {
                        AppLanguage.applySelection(appLanguage)
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                    }
                }
            }
            .environmentObject(terminalNotificationNavigation)
            .environmentObject(appLockManager)
            .environmentObject(serverManager)
            .environmentObject(storeManager)
            .environmentObject(terminalFontStore)
            .environmentObject(viewTabConfigurationManager)
            .environmentObject(syncSettingsCoordinator)
            .environmentObject(sshKeySettingsCoordinator)
            .environmentObject(knownHostSettingsCoordinator)
        }
        #if os(macOS)
        .onChange(of: terminalNotificationNavigation.pending) { destination in
            guard destination != nil else { return }
            if !MainWindowChromeBridge.bringMainWindowForward(in: NSApp.orderedWindows + NSApp.windows) {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            VVTermCommands(
                aboutWindowPresenter: aboutWindowPresenter,
                settingsWindowPresenter: settingsWindowPresenter
            )
        }
        #endif
    }
}

#if os(iOS)
private enum VVTermLauncherWidgetRefresh {
    private static let renderingRevision = 1
    private static let renderingRevisionKey = "launcherWidgetRenderingRevision"

    static func refreshIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: renderingRevisionKey) < renderingRevision else { return }

        WidgetCenter.shared.reloadTimelines(ofKind: VVTermWidgetKind.launcher)
        defaults.set(renderingRevision, forKey: renderingRevisionKey)
    }
}
#endif
