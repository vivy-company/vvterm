//
//  ServerTerminalRoute+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
import UIKit

// MARK: - Server Terminal Route

struct ServerTerminalRoute: View {
    private enum PresentedRouteSheet: Hashable, Identifiable {
        case settings
        case sessions

        var id: Self { self }
    }

    let tabManager: TerminalTabManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let statsDependencies: ServerStatsScreenDependencies
    let terminalSecurityActions: TerminalSecurityActions
    let serverFormDependencies: ServerFormDependencies
    let voiceModelManagers: VoiceSettingsModelManagerOwner
    let voiceInputRuntimeStore: VoiceInputRuntimeStore
    let analyticsOptOutAction: AnalyticsOptOutAction
    let route: ServerTerminalNavigationRoute
    let onToggleSidebar: (() -> Void)?
    let onSessionServerSelected: ((Server) -> Void)?
    let onBack: () -> Void
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory

    private let keyboardCoordinator: TerminalKeyboardCoordinator
    @StateObject private var toolbarProjection: TerminalServerToolbarProjection
    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager
    @EnvironmentObject private var appLockManager: AppLockManager
    @EnvironmentObject private var screenAwakeCoordinator: TerminalScreenAwakeCoordinator
    @EnvironmentObject private var storeManager: StoreManager

    @State private var isRouteVisible = false
    @State private var screenAwakeRequestID = UUID()
    @State private var presentedRouteSheet: PresentedRouteSheet?
    @State private var isTerminalChildModalPresented = false
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @SceneStorage("vvterm.zenMode.ios") private var isZenModeEnabled = false
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false
    @AppStorage(TerminalDefaults.keepScreenAwakeKey) private var keepScreenAwakeEnabled = TerminalDefaults.defaultKeepScreenAwake
    @Environment(\.scenePhase) private var scenePhase

    init(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        fileTabs: RemoteFileTabManager,
        fileBrowser: RemoteFileBrowserStore,
        statsDependencies: ServerStatsScreenDependencies,
        terminalSecurityActions: TerminalSecurityActions,
        serverFormDependencies: ServerFormDependencies,
        voiceModelManagers: VoiceSettingsModelManagerOwner,
        voiceInputRuntimeStore: VoiceInputRuntimeStore,
        analyticsOptOutAction: AnalyticsOptOutAction,
        route: ServerTerminalNavigationRoute,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        onToggleSidebar: (() -> Void)? = nil,
        onSessionServerSelected: ((Server) -> Void)? = nil,
        onBack: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.serverManager = serverManager
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.statsDependencies = statsDependencies
        self.terminalSecurityActions = terminalSecurityActions
        self.serverFormDependencies = serverFormDependencies
        self.voiceModelManagers = voiceModelManagers
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.analyticsOptOutAction = analyticsOptOutAction
        self.route = route
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.onToggleSidebar = onToggleSidebar
        self.onSessionServerSelected = onSessionServerSelected
        self.onBack = onBack
        self.keyboardCoordinator = tabManager.keyboardCoordinator
        let toolbarProjection = TerminalServerToolbarProjection(
            serverId: route.serverId,
            tabManager: tabManager
        )
        self._toolbarProjection = StateObject(wrappedValue: toolbarProjection)
    }

    private var terminalContent: TerminalServerContentProjection {
        toolbarProjection.content
    }

    private var floatingControls: TerminalServerFloatingControlProjection {
        toolbarProjection.floatingControls
    }

    private var selectedServer: Server? {
        if let server = serverManager.servers.first(where: { $0.id == route.serverId }) {
            return server
        }
        return route.connectingServer
    }

    private var selectedView: ConnectionViewTabID {
        guard selectedServer != nil else {
            return viewTabConfig.effectiveDefaultTab()
        }
        return viewTabConfig.effectiveView(for: terminalContent.state.selectedView)
    }

    private var selectedTab: TerminalTab? {
        guard let selectedTabId = terminalContent.state.selectedTabId else { return nil }
        return terminalContent.state.tabs.first { $0.id == selectedTabId }
    }

    private var selectedFileTab: RemoteFileTab? {
        guard let server = selectedServer else { return nil }
        return fileTabs.selectedTab(for: server.id)
    }

    private var focusedTerminal: GhosttyTerminalView? {
        guard let paneId = selectedTab?.focusedPaneId else { return nil }
        return tabManager.terminalSurfaceStore.ghosttySurface(for: paneId)
    }

    private var focusedPaneId: UUID? {
        selectedTab?.focusedPaneId
    }

    private var canEnterZenMode: Bool {
        TerminalZenModePolicy.canEnter(
            isTerminalSelected: selectedView == .terminal,
            hasActiveTerminal: selectedTab != nil
        )
    }

    private var hasNavigationContext: Bool {
        route.isConnecting
            || !terminalContent.state.tabs.isEmpty
            || !fileTabs.tabs(for: route.serverId).isEmpty
    }

    private var isFocusedTerminalFindNavigatorVisible: Bool {
        floatingControls.state.findNavigatorIsVisible
    }

    var body: some View {
        #if DEBUG
        let _ = TerminalRouteUITestRenderProbe.recordUpdate()
        #endif
        content
            .navigationTitle("")
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationToolbar }
            .toolbar(isZenModeEnabled ? .hidden : .visible, for: .navigationBar)
            .toolbar(isZenModeEnabled ? .hidden : .automatic, for: .bottomBar)
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .sheet(item: $presentedRouteSheet, onDismiss: updateTerminalRouteActivation) { sheet in
                switch sheet {
                case .sessions:
                    SessionsScreen(serverManager: serverManager, tabManager: tabManager,
                                   fileTabs: fileTabs, fileBrowser: fileBrowser, selectedServerID: route.serverId) { server in
                        presentedRouteSheet = nil
                        onSessionServerSelected?(server)
                    }
                case .settings:
                    SettingsView(
                        statsPreferencesStore: statsDependencies.preferencesStore,
                        voiceModelManagers: voiceModelManagers,
                        analyticsOptOutAction: analyticsOptOutAction,
                        remoteSessionBackends: tabManager.remoteSessionCoordinator.backendMetadata
                    )
                        .modifier(AppearanceModifier())
                        .adaptiveSoftScrollEdges()

                }
            }
            .onAppear {
                isRouteVisible = true
                dismissIfContextEnded()
                reconcileZenMode()
                updateTerminalRouteActivation()
            }
            .onDisappear {
                isRouteVisible = false
                tabManager.reconnectCoordinator.invalidatePreparations(forServer: route.serverId)
                keyboardCoordinator.setViewActive(false)
                keyboardCoordinator.setActivePane(nil)
                screenAwakeCoordinator.update(isRequested: false, for: screenAwakeRequestID)
            }
            .onChange(of: selectedView) { newValue in
                if newValue != .terminal {
                    clearPendingVoiceReturnForFocusedPane()
                }
                reconcileZenMode()
                updateTerminalRouteActivation()
            }
            .onChange(of: selectedTab?.id) { _ in
                reconcileZenMode()
                updateTerminalRouteActivation()
            }
            .onChange(of: focusedPaneId) { _ in
                updateTerminalRouteActivation()
            }
            .onReceive(tabManager.terminalSurfaceStore.changes) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: terminalContent.state.tabs) { _ in
                dismissIfContextEnded()
                reconcileZenMode()
                updateTerminalRouteActivation()
            }
            .onChange(of: fileTabs.tabsByServer) { _ in
                dismissIfContextEnded()
                updateTerminalRouteActivation()
            }
            .onChange(of: scenePhase) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: isContentObscured) { _ in
                updateTerminalRouteActivation()
            }
            .onChange(of: keepScreenAwakeEnabled) { _ in
                updateTerminalRouteActivation()
            }
            .onPreferenceChange(TerminalRouteModalPresentationPreferenceKey.self) {
                updateTerminalChildModalPresentation($0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
                handleSceneDidActivate(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
                handleSceneWillDeactivate(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { notification in
                handleTerminalWindowKeyChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didResignKeyNotification)) { notification in
                handleTerminalWindowKeyChange(notification)
            }
            .onChange(of: isFocusedTerminalFindNavigatorVisible) { _ in
                updateTerminalRouteActivation()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let server = selectedServer {
            ConnectionTerminalContainer(
                tabManager: tabManager,
                terminalToolbarProjection: toolbarProjection,
                fileTabManager: fileTabs,
                serverManager: serverManager,
                fileBrowser: fileBrowser,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                statsDependencies: statsDependencies,
                terminalSecurityActions: terminalSecurityActions,
                serverFormDependencies: serverFormDependencies,
                voiceInputRuntimeStore: voiceInputRuntimeStore,
                server: server,
                isZenModeEnabled: $isZenModeEnabled,
                isSidebarVisible: false,
                onToggleSidebar: {},
                onOpenSettings: { presentRouteSheet(.settings) },
                onLeaveRoute: leaveRoute,
                onDisconnectRoute: { disconnect(server) },
                canOpenSessions: onSessionServerSelected != nil,
                onSessionCommand: performSessionCommand
            )
        } else if route.isConnecting {
            connectingStateView(
                serverName: route.connectingServer?.name ?? String(localized: "Server")
            )
        } else {
            TerminalEmptyStateView(server: nil) {
                leaveRoute()
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if let onToggleSidebar {
                Button(action: onToggleSidebar) { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Sidebar")
                    .accessibilityIdentifier("vvterm.sidebar.toggle")
                    .keyboardShortcut("s", modifiers: [.control, .command])
            } else {
                Button { leaveRoute() } label: { Image(systemName: "chevron.left") }
                    .accessibilityIdentifier("vvterm.terminal.back")
            }
        }

        if let server = selectedServer, viewTabConfig.currentVisibleTabs.count > 1 {
            if #available(iOS 27.1, *) {
                ConnectionViewPickerToolbar(
                    selection: selectedViewBinding(for: server.id),
                    tabs: viewTabConfig.currentVisibleTabs
                )
            } else {
                ToolbarItem(placement: .principal) {
                    ConnectionViewSegmentedPicker(
                        selection: selectedViewBinding(for: server.id),
                        tabs: viewTabConfig.currentVisibleTabs
                    )
                    .fixedSize()
                }
            }
        }

        if #available(iOS 27.1, *) {
            AdaptiveActionsToolbar { connectionActions }
        } else {
            ToolbarItemGroup(placement: .navigationBarTrailing) { connectionActions }
        }
    }

    @ViewBuilder
    private var connectionActions: some View {
        if let server = selectedServer, selectedView == .terminal {
            Button {
                openNewTab(for: server)
            } label: {
                Image(systemName: "plus")
            }
        }

        if let server = selectedServer, selectedView == .files {
            Button {
                openNewFileTab(for: server)
            } label: {
                Image(systemName: "plus")
            }
        }

        Menu {
            TerminalSessionMenuActions(
                style: .menu,
                isTerminalSelected: selectedServer != nil && selectedView == .terminal,
                zenMode: canEnterZenMode ? (isZenModeEnabled ? .active : .inactive) : .unavailable,
                composer: focusedPaneId.map {
                    tabManager.richPasteRuntimeStore.runtime(for: $0, tabManager: tabManager).composer
                },
                canOpenSessions: onSessionServerSelected != nil,
                canDisconnect: selectedServer != nil,
                perform: performSessionCommand
            )
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("vvterm.terminal.moreMenu")
    }

    private func performSessionCommand(_ command: TerminalSessionCommand) {
        switch command {
        case .sessions:
            presentRouteSheet(.sessions)
        case .find:
            focusedTerminal?.showFindNavigator()
        case .keyboard:
            performKeyboardCommandForFocusedTerminal()
        case .toggleZen:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isZenModeEnabled.toggle()
            }
        case .settings:
            presentRouteSheet(.settings)
        case .disconnect:
            if let server = selectedServer {
                statsDependencies.runtimeStore.releaseCollector(for: server.id)
                disconnect(server)
            }
        }
    }

    private func selectedViewBinding(for serverId: UUID) -> Binding<ConnectionViewTabID> {
        Binding(
            get: {
                viewTabConfig.effectiveView(
                    for: tabManager.connectionViewSelections.selection(for: serverId)
                )
            },
            set: { newValue in
                tabManager.sessionState.selectView(viewTabConfig.effectiveView(for: newValue), for: serverId)
            }
        )
    }

    /// Prefer the terminal's own UIKit scene because SwiftUI's scenePhase can
    /// lag under iPhone Mirroring and another foreground scene must not make
    /// this route appear active.
    private var terminalSceneActivation: TerminalKeyboardRouteActivationPolicy.SceneActivation {
        if let activationState = focusedTerminal?.window?.windowScene?.activationState {
            switch activationState {
            case .foregroundActive:
                return .foregroundActive
            case .foregroundInactive:
                return .foregroundInactive
            case .background, .unattached:
                return .background
            @unknown default:
                return .background
            }
        }

        switch scenePhase {
        case .active:
            return .foregroundActive
        case .inactive:
            return .foregroundInactive
        case .background:
            return .background
        @unknown default:
            return .background
        }
    }

    private var isContentObscured: Bool {
        let terminalSceneIsActive: Bool
        switch terminalSceneActivation {
        case .foregroundActive:
            terminalSceneIsActive = true
        case .foregroundInactive, .background:
            terminalSceneIsActive = false
        }
        return AppContentProtectionPolicy.shouldObscureContent(
            sceneIsActive: terminalSceneIsActive,
            fullAppLockEnabled: appLockManager.fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: appLockManager.isAppLocked
        )
    }

    private var keyboardPresentationOwnership: TerminalKeyboardRouteActivationPolicy.PresentationOwnership {
        presentedRouteSheet == nil && !isTerminalChildModalPresented
            ? .terminal
            : .routeModal
    }

    private func updateTerminalChildModalPresentation(_ isPresented: Bool) {
        guard isTerminalChildModalPresented != isPresented else { return }
        isTerminalChildModalPresented = isPresented
        if isPresented {
            keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
        } else {
            updateTerminalRouteActivation()
        }
    }

    private var screenAwakeSceneIsInBackground: Bool {
        switch terminalSceneActivation {
        case .foregroundActive, .foregroundInactive:
            false
        case .background:
            true
        }
    }

    private func handleSceneWillDeactivate(_ notification: Notification) {
        if let notifyingScene = notification.object as? UIScene,
           let terminalScene = focusedTerminal?.window?.windowScene,
           notifyingScene !== terminalScene {
            return
        }

        // Freeze the current grid before UIKit removes the software keyboard
        // and expands the terminal layout during the app-switch transition.
        focusedTerminal?.pauseRendering(
            preservingForegroundKeyboardGrid: keyboardCoordinator.softwareKeyboardEndFrame != nil
        )

        if keyboardCoordinator.activeInputMode == .chat,
           !appLockManager.fullAppLockEnabled, !appLockManager.isAppLocked {
            if let focusedPaneId {
                keyboardCoordinator.activeTerminalSceneWillDeactivate(for: focusedPaneId)
            }
        } else if AppContentProtectionPolicy.shouldPrepareForSceneDeactivation(
            fullAppLockEnabled: appLockManager.fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: appLockManager.isAppLocked
        ) {
            keyboardCoordinator.deactivateInputImmediately()
        } else {
            if let focusedPaneId {
                keyboardCoordinator.activeTerminalSceneWillDeactivate(for: focusedPaneId)
            }
            updateTerminalRouteActivation()
        }
    }

    private func handleSceneDidActivate(_ notification: Notification) {
        guard let notifyingScene = notification.object as? UIScene,
              let terminal = focusedTerminal,
              notifyingScene === terminal.window?.windowScene else {
            return
        }

        updateTerminalRouteActivation()
        guard let focusedPaneId else { return }
        keyboardCoordinator.activeTerminalSceneDidActivate(for: focusedPaneId)
    }

    private func handleTerminalWindowKeyChange(_ notification: Notification) {
        guard let notifyingWindow = notification.object as? UIWindow,
              notifyingWindow === focusedTerminal?.window else {
            return
        }
        updateTerminalRouteActivation()
        if notifyingWindow.isKeyWindow,
           notifyingWindow.windowScene?.activationState == .foregroundActive,
           let focusedPaneId {
            keyboardCoordinator.activeTerminalSceneDidActivate(for: focusedPaneId)
        }
    }

    private func updateTerminalRouteActivation() {
        let presentationOwnership = keyboardPresentationOwnership
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: isRouteVisible,
            terminalSelected: selectedView == .terminal,
            sceneActivation: terminalSceneActivation,
            windowOwnership: focusedTerminal?.window.map {
                $0.isKeyWindow ? .key : .notKey
            } ?? .unknown,
            presentationOwnership: presentationOwnership,
            contentObscured: isContentObscured,
            appLockRequired: appLockManager.fullAppLockEnabled || appLockManager.isAppLocked,
            inputMode: keyboardCoordinator.activeInputMode
        )

        screenAwakeCoordinator.update(
            isRequested: TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: keepScreenAwakeEnabled,
                routeVisible: isRouteVisible,
                terminalSelected: selectedView == .terminal,
                sceneIsInBackground: screenAwakeSceneIsInBackground
            ),
            for: screenAwakeRequestID
        )

        if effect == .suspend {
            if let focusedPaneId {
                keyboardCoordinator.activeTerminalSceneWillDeactivate(for: focusedPaneId)
            }
            return
        }

        if effect == .deactivate {
            if isContentObscured {
                keyboardCoordinator.deactivateInputImmediately()
                return
            }
            if presentationOwnership == .routeModal {
                keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
                return
            }
        }

        let activePaneId = effect == .activate ? focusedPaneId : nil

        keyboardCoordinator.setActivePane(activePaneId)
        keyboardCoordinator.setViewActive(effect == .activate)
        if let activePaneId {
            keyboardCoordinator.setFindNavigatorActive(
                isFocusedTerminalFindNavigatorVisible,
                for: activePaneId
            )
            if keyboardCoordinator.contentProtectionRecoveryIsPending(for: activePaneId),
               let terminal = focusedTerminal {
                terminal.resumeRendering()
                keyboardCoordinator.activeTerminalContentDidBecomeVisible(for: activePaneId)
            }
        }
    }

    private func dismissIfContextEnded() {
        guard !hasNavigationContext else { return }
        isZenModeEnabled = false
        leaveRoute()
    }

    private func leaveRoute() {
        isZenModeEnabled = false
        tabManager.reconnectCoordinator.invalidatePreparations(forServer: route.serverId)
        keyboardCoordinator.relinquishRouteOwnershipForNavigation()
        onBack()
    }

    private func reconcileZenMode() {
        isZenModeEnabled = TerminalZenModePolicy.resolvedEnabled(
            requested: isZenModeEnabled,
            hasRouteContext: hasNavigationContext
        )
    }

    private func presentRouteSheet(_ sheet: PresentedRouteSheet) {
        // Publish ownership first: resigning input can synchronously deliver
        // window/focus callbacks which also evaluate route activation.
        presentedRouteSheet = sheet
        keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
    }

    private func performKeyboardCommandForFocusedTerminal() {
        guard selectedView == .terminal else { return }
        clearPendingVoiceReturnForFocusedPane()
        keyboardCoordinator.userRequestedKeyboardCommand()
        focusedTerminal?.dismissFindNavigator()
    }

    private func clearPendingVoiceReturnForFocusedPane() {
        guard let focusedPaneId else { return }
        tabManager.presentationState.applyVoiceEvent(.pendingReturnDismissed, for: focusedPaneId)
    }

    private func openNewTab(for server: Server) {
        guard tabManager.sessionState.canOpenNewTab(hasProAccess: storeManager.allowsProFeatures) else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                tabManager.sessionState.selectView(viewTabConfig.effectiveView(for: .terminal), for: server.id)
                tabManager.sessionState.selectTab(tab.id, for: server.id)
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    private func openNewFileTab(for server: Server) {
        guard fileTabs.canOpenNewTab(
            for: server.id,
            hasProAccess: storeManager.allowsProFeatures
        ) else {
            showingFileTabLimitAlert = true
            return
        }

        let sourceTab = selectedFileTab
        let seedPath = sourceTab.flatMap { fileBrowser.lastVisitedPath(for: $0) }
            ?? selectedTab.flatMap {
                tabManager.sessionState.paneState(for: $0.focusedPaneId)?.workingDirectory
            }
        let newTab = sourceTab.flatMap {
            fileTabs.duplicateTab(
                $0,
                seedPath: seedPath,
                hasProAccess: storeManager.allowsProFeatures
            )
        } ?? fileTabs.openTab(
            for: server,
            seedPath: seedPath,
            hasProAccess: storeManager.allowsProFeatures
        )

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)
        tabManager.sessionState.selectView(viewTabConfig.effectiveView(for: .files), for: server.id)
    }

    private func disconnect(_ server: Server) {
        isZenModeEnabled = false
        fileBrowser.disconnect(serverId: server.id)
        fileTabs.disconnect(serverId: server.id)
        tabManager.disconnectServer(server.id)
        dismissIfContextEnded()
    }

    @ViewBuilder
    private func connectingStateView(serverName: String) -> some View {
        BlockingStatusView(showsScrim: false) {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(String(format: String(localized: "Connecting to %@..."), serverName))
                    .font(.headline)
                Text(String(localized: "Preparing server details..."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
