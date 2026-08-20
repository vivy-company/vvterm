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
        _storeManager = StateObject(wrappedValue: composition.storeManager)
        _appLockManager = StateObject(wrappedValue: composition.appLockManager)
        _serverManager = StateObject(wrappedValue: composition.serverManager)
        _engagementTracker = StateObject(wrappedValue: composition.engagementTracker)
        _remoteFileBrowserStore = StateObject(wrappedValue: composition.remoteFileBrowserStore)
        _terminalThemeManager = StateObject(wrappedValue: composition.terminalThemeManager)
        _terminalAccessoryPreferencesManager = StateObject(
            wrappedValue: composition.terminalAccessoryPreferencesManager
        )
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
            serverManager: composition.serverManager,
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

    @StateObject private var ghosttyApp: GhosttyRuntime
    #if os(iOS)
    @StateObject private var screenAwakeCoordinator = TerminalScreenAwakeCoordinator()
    private let analyticsOptOutAction: AnalyticsOptOutAction
    #endif
    @StateObject private var appLockManager: AppLockManager
    @StateObject private var serverManager: ServerManager
    @StateObject private var engagementTracker: EngagementTracker
    private let networkMonitor: NetworkMonitor
    private let tabManager: TerminalTabManager
    @StateObject private var storeManager: StoreManager
    @StateObject private var remoteFileTabManager = RemoteFileTabManager()
    @StateObject private var remoteFileBrowserStore: RemoteFileBrowserStore
    @StateObject private var terminalThemeManager: TerminalThemeManager
    @StateObject private var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
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
    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = TerminalDefaults.defaultFontName
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.cursorStyleKey) private var terminalCursorStyle = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var terminalCursorBlink = TerminalDefaults.defaultCursorBlink
    #if os(macOS)
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var terminalOptionAsAltMode = TerminalOptionAsAltMode.none.rawValue
    #endif
    @AppStorage(TerminalRemoteClipboardReadPolicy.userDefaultsKey)
    private var remoteClipboardReadPolicy = TerminalRemoteClipboardReadPolicy.defaultValue.rawValue

    private var terminalOptionAsAltModeRawValue: String {
        #if os(macOS)
        terminalOptionAsAltMode
        #else
        TerminalOptionAsAltMode.none.rawValue
        #endif
    }

    private var ghosttyRuntimeConfiguration: Ghostty.RuntimeConfiguration {
        Ghostty.RuntimeConfiguration(
            fontName: terminalFontName,
            fontSize: terminalFontSize,
            cursorStyleRawValue: terminalCursorStyle,
            cursorBlink: terminalCursorBlink,
            optionAsAltModeRawValue: terminalOptionAsAltModeRawValue,
            remoteClipboardReadPolicyRawValue: remoteClipboardReadPolicy
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
        if usesSyncSettingsUITestHarness {
            SyncSettingsUITestHarness()
        } else if usesTrustedHostsSettingsUITestHarness {
            TrustedHostsSettingsUITestHarness()
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
        if usesSyncSettingsUITestHarness {
            SyncSettingsUITestHarness()
        } else if usesTrustedHostsSettingsUITestHarness {
            TrustedHostsSettingsUITestHarness()
        } else if usesNoticePresentationUITestHarness {
            NoticePresentationUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesStatsCardsLayoutUITestHarness {
            StatsCardsLayoutUITestHarness()
                .modifier(AppearanceModifier())
        } else if usesTerminalZenModeUITestHarness {
            TerminalZenModeUITestHarness(tabManager: tabManager)
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
            TerminalKeyboardUITestHarness(tabManager: tabManager)
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
                        #else
                        macOSRootContent
                        #endif
                    }
                    .adaptiveSoftScrollEdges()
                    .environment(\.locale, appLocale)
                    .environment(\.privacyModeEnabled, privacyModeEnabled)
                    .onAppear {
                        AppLanguage.applySelection(appLanguage)
                        serverManager.handleAppLanguageChange()
                    }
                    .onChange(of: appLanguage) { newValue in
                        AppLanguage.applySelection(newValue)
                        serverManager.handleAppLanguageChange()
                    }
                }
            }
            .environmentObject(appLockManager)
            .environmentObject(serverManager)
            .environmentObject(storeManager)
            .environmentObject(viewTabConfigurationManager)
            .environmentObject(syncSettingsCoordinator)
            .environmentObject(sshKeySettingsCoordinator)
            .environmentObject(knownHostSettingsCoordinator)
        }
        #if os(macOS)
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
