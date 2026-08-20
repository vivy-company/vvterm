//
//  ContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ContentView: View {
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let statsDependencies: ServerStatsScreenDependencies
    let terminalSecurityActions: TerminalSecurityActions
    let serverFormDependencies: ServerFormDependencies
    let workspaceSelectionStore: WorkspaceSelectionStore
    let voiceInputRuntimeStore: VoiceInputRuntimeStore
    let onOpenSettings: () -> Void
    private let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    @ObservedObject private var serverManager: ServerManager
    @ObservedObject private var engagementTracker: EngagementTracker
    private let tabManager: TerminalTabManager
    @StateObject private var terminalNavigation: TerminalSessionNavigationProjection
    @EnvironmentObject private var appLockManager: AppLockManager
    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.requestReview) private var requestReview
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @EnvironmentObject private var viewTabConfigurationManager: ViewTabConfigurationManager

    #if os(macOS)
    // Re-injected into the AppKit-hosted sidebar/detail panes, since environment
    // values do not cross an NSHostingController boundary automatically.
    @EnvironmentObject private var ghosttyApp: GhosttyRuntime
    @EnvironmentObject private var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    @Environment(\.locale) private var locale
    @Environment(\.privacyModeEnabled) private var privacyModeEnabled
    // Republishes the hosted detail pane's command actions as scene focus
    // values so the menu commands (Cmd+T/W, tab nav, splits) can reach them.
    @StateObject private var commandBridge = MacShellCommandBridge()
    #endif

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var restoredColumnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("vvterm.zenMode.macos") private var isZenModeEnabled = false

    init(
        serverManager: ServerManager,
        engagementTracker: EngagementTracker,
        tabManager: TerminalTabManager,
        fileTabs: RemoteFileTabManager,
        fileBrowser: RemoteFileBrowserStore,
        statsDependencies: ServerStatsScreenDependencies,
        terminalSecurityActions: TerminalSecurityActions,
        serverFormDependencies: ServerFormDependencies,
        workspaceSelectionStore: WorkspaceSelectionStore,
        voiceInputRuntimeStore: VoiceInputRuntimeStore,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        onOpenSettings: @escaping () -> Void
    ) {
        _serverManager = ObservedObject(wrappedValue: serverManager)
        _engagementTracker = ObservedObject(wrappedValue: engagementTracker)
        self.tabManager = tabManager
        _terminalNavigation = StateObject(
            wrappedValue: TerminalSessionNavigationProjection(
                sessionState: tabManager.sessionState
            )
        )
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.statsDependencies = statsDependencies
        self.terminalSecurityActions = terminalSecurityActions
        self.serverFormDependencies = serverFormDependencies
        self.workspaceSelectionStore = workspaceSelectionStore
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.onOpenSettings = onOpenSettings
    }

    /// Whether the selected server has an open terminal/file surface.
    private var selectedServerHasOpenConnectionSurface: Bool {
        guard let selected = selectedServer else { return false }
        return hasOpenConnectionSurface(for: selected.id)
    }

    /// Whether any server has an open terminal/file surface.
    private var hasOpenConnectionSurfaces: Bool {
        !terminalNavigation.state.serverIdsWithTabs.isEmpty
            || fileTabs.tabsByServer.values.contains { !$0.isEmpty }
            || !terminalNavigation.state.connectedServerIds.isEmpty
    }

    private var canUseZenMode: Bool {
        guard let selected = selectedServer else { return false }
        return terminalNavigation.state.connectedServerIds.contains(selected.id)
    }

    private var effectiveZenModeEnabled: Bool {
        canUseZenMode && isZenModeEnabled
    }

    private var terminalAppearanceSnapshot: TerminalAppearanceSnapshot {
        terminalThemeManager.appearanceSnapshot(
            for: colorScheme == .dark ? .dark : .light
        )
    }

    private var macOSWindowBackgroundColor: Color {
        Color.fromHex(terminalAppearanceSnapshot.activeTheme.palette.backgroundHex)
    }

    #if os(macOS)
    private var zenWindowTitle: String {
        guard effectiveZenModeEnabled, let selectedServer else { return "" }
        return selectedServer.name
    }

    private var zenNavigationTitle: String {
        guard effectiveZenModeEnabled, let selectedServer else { return "" }
        return selectedServer.name
    }

    private var macSidebarContentIdentity: String {
        "\(locale.identifier)|\(privacyModeEnabled)"
    }

    private var macDetailContentIdentity: String {
        [
            selectedServer?.id.uuidString ?? "none",
            String(selectedServerHasOpenConnectionSurface),
            String(hasOpenConnectionSurfaces),
            String(describing: storeManager.accessState),
            colorScheme == .dark ? "dark" : "light",
            locale.identifier,
            String(privacyModeEnabled)
        ].joined(separator: "|")
    }
    #endif

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    @ViewBuilder
    private var detailContent: some View {
        if let server = selectedServer {
            // A server is selected
            if selectedServerHasOpenConnectionSurface {
                // Server has an open connection surface - show its container
                TerminalServerToolbarProjectionHost(
                    serverId: server.id,
                    tabManager: tabManager
                ) { toolbarProjection in
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
                        isSidebarVisible: isSidebarVisible,
                        onToggleSidebar: toggleSidebarInZenMode,
                        onOpenSettings: onOpenSettings,
                        onLeaveRoute: nil,
                        onDisconnectRoute: nil
                    )
                }
                .id(server.id) // Ensure isolation per server
            } else if !hasOpenConnectionSurfaces {
                // No open connection surfaces - can connect freely
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else if storeManager.allowsProFeatures {
                // Pro user already has other open connection surfaces - can connect to more
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else {
                // Free user already has another open connection surface - show upgrade
                MultiConnectionUpgradeEmptyState(server: server)
            }
        } else {
            // Nothing selected
            NoServerSelectedEmptyState()
        }
    }

    private func hasOpenConnectionSurface(for serverId: UUID) -> Bool {
        terminalNavigation.state.tabCountsByServer[serverId, default: 0] > 0
            || !fileTabs.tabs(for: serverId).isEmpty
            || terminalNavigation.state.connectedServerIds.contains(serverId)
    }

    private func connectToServer(_ server: Server) {
        Task {
            guard await appLockManager.ensureServerUnlocked(server) else { return }
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    tabManager.sessionState.selectView(
                        viewTabConfigurationManager.effectiveDefaultTab(),
                        for: server.id
                    )
                    tabManager.sessionState.selectTab(tab.id, for: server.id)
                }
            } catch {
                // No-op: user cancelled biometric auth or the tab limit blocked the open.
            }
        }
    }

    private func applyZenPresentation(_ enabled: Bool) {
        if enabled {
            if columnVisibility != .detailOnly {
                restoredColumnVisibility = columnVisibility
            }
            columnVisibility = .detailOnly
        } else if columnVisibility == .detailOnly {
            columnVisibility = restoredColumnVisibility == .detailOnly ? .all : restoredColumnVisibility
        }
    }

    private func setZenMode(_ enabled: Bool) {
        guard enabled != isZenModeEnabled else { return }
        isZenModeEnabled = enabled
    }

    private func toggleZenMode() {
        guard canUseZenMode || isZenModeEnabled else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            setZenMode(!isZenModeEnabled)
        }
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        if isVisible {
            columnVisibility = restoredColumnVisibility == .detailOnly ? .all : restoredColumnVisibility
        } else {
            if columnVisibility != .detailOnly {
                restoredColumnVisibility = columnVisibility
            }
            columnVisibility = .detailOnly
        }
    }

    private func toggleSidebarInZenMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            setSidebarVisible(!isSidebarVisible)
        }
    }

    private var zenToggleAction: (() -> Void)? {
        guard canUseZenMode else { return nil }
        return { toggleZenMode() }
    }

    /// Shared workspace-seeding and zen-presentation lifecycle, applied to both
    /// the iOS NavigationSplitView and the macOS AppKit shell host.
    private func withSplitLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                selectedWorkspace = WorkspaceSelectionPolicy.workspace(
                    current: selectedWorkspace,
                    available: serverManager.workspaces
                )
                if !canUseZenMode {
                    setZenMode(false)
                } else if isZenModeEnabled {
                    applyZenPresentation(true)
                }
            }
            .onChange(of: serverManager.workspaces) { workspaces in
                selectedWorkspace = WorkspaceSelectionPolicy.workspace(
                    current: selectedWorkspace,
                    available: workspaces
                )
            }
            .onChange(of: columnVisibility) { newValue in
                if !isZenModeEnabled && newValue != .detailOnly {
                    restoredColumnVisibility = newValue
                }
            }
            .onChange(of: isZenModeEnabled) { enabled in
                applyZenPresentation(enabled && canUseZenMode)
            }
            .onChange(of: canUseZenMode) { available in
                if !available && isZenModeEnabled {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        setZenMode(false)
                    }
                }
            }
    }

    private var splitViewContent: some View {
        withSplitLifecycle(
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // LEFT: Sidebar with workspace + servers
                ServerSidebarView(
                    serverManager: serverManager,
                    tabManager: tabManager,
                    terminalNavigation: terminalNavigation,
                    serverFormDependencies: serverFormDependencies,
                    workspaceSelectionStore: workspaceSelectionStore,
                    makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                    onOpenSettings: onOpenSettings,
                    selectedWorkspace: $selectedWorkspace,
                    selectedServer: $selectedServer
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
            } detail: {
                // RIGHT: Detail view based on selection state
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(macOSWindowBackgroundColor)
                    #if os(macOS)
                    .navigationTitle(zenNavigationTitle)
                    #endif
            }
        )
    }

    #if os(macOS)
    /// macOS shell: the sidebar + detail hosted inside an AppKit
    /// NSSplitViewController so the window toolbar can be owned by a custom
    /// NSToolbar (added in a later stage).
    private var macShellContent: some View {
        withSplitLifecycle(
            MacShellSplitHost(
                isSidebarCollapsed: columnVisibility == .detailOnly,
                sidebarContentIdentity: macSidebarContentIdentity,
                detailContentIdentity: macDetailContentIdentity,
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        setSidebarVisible(!isSidebarVisible)
                    }
                },
                sidebar: {
                    withShellEnvironment(
                        ServerSidebarView(
                            serverManager: serverManager,
                            tabManager: tabManager,
                            terminalNavigation: terminalNavigation,
                            serverFormDependencies: serverFormDependencies,
                            workspaceSelectionStore: workspaceSelectionStore,
                            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                            onOpenSettings: onOpenSettings,
                            selectedWorkspace: $selectedWorkspace,
                            selectedServer: $selectedServer
                        )
                    )
                },
                detail: {
                    withShellEnvironment(
                        detailContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(macOSWindowBackgroundColor)
                    )
                }
            )
            .ignoresSafeArea()
        )
    }

    /// Re-injects the environment the hosted panes require, since it does not
    /// cross the NSHostingController boundary.
    private func withShellEnvironment<V: View>(_ view: V) -> some View {
        view
            .environmentObject(ghosttyApp)
            .environmentObject(terminalThemeManager)
            .environmentObject(terminalAccessoryPreferencesManager)
            .environmentObject(appLockManager)
            .environmentObject(serverManager)
            .environmentObject(storeManager)
            .environmentObject(viewTabConfigurationManager)
            .environmentObject(commandBridge)
            .environment(\.locale, locale)
            .environment(\.privacyModeEnabled, privacyModeEnabled)
    }
    #endif

    var body: some View {
        #if os(macOS)
        macShellContent
            .onChange(of: engagementTracker.reviewRequestToken) { _ in
                requestReview()
            }
            .focusedSceneValue(\.toggleZenMode, zenToggleAction)
            .focusedSceneValue(\.isZenModeEnabled, canUseZenMode ? effectiveZenModeEnabled : nil)
            .focusedSceneValue(\.serverViewTabActions, commandBridge.serverViewTabActions)
            .focusedSceneValue(\.terminalSplitActions, commandBridge.splitActions)
            .focusedSceneValue(\.activeServerId, commandBridge.activeServerId)
            .focusedSceneValue(\.activePaneId, commandBridge.activePaneId)
            .focusedSceneValue(\.openLocalSSHDiscovery, commandBridge.openLocalDiscovery)
            .background(
                MainWindowChromeBridge(
                    windowTitle: zenWindowTitle,
                    backgroundColor: macOSWindowBackgroundColor
                )
                    .frame(width: 0, height: 0)
            )
            .frame(minWidth: 800, minHeight: 500)
        #endif
        #if !os(macOS)
        splitViewContent
        #endif
    }
}

// MARK: - Preview

#Preview("App Shell") {
    AppPreviewComposition().rootView
}

#if os(macOS)
private struct MainWindowChromeBridge: NSViewRepresentable {
    let windowTitle: String
    let backgroundColor: Color

    func makeNSView(context: Context) -> NSView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObserverView else { return }
        view.windowTitle = windowTitle
        view.backgroundColor = backgroundColor
        view.applyIfPossible()
    }

    private static func configure(_ window: NSWindow, title: String, backgroundColor: Color) {
        let nsBackgroundColor = NSColor(backgroundColor)
        if window.title != title {
            window.title = title
        }
        window.backgroundColor = nsBackgroundColor
        window.titleVisibility = title.isEmpty ? .hidden : .visible
        if title.isEmpty {
            window.subtitle = ""
        }
        window.titlebarAppearsTransparent = true
        // Keep the content area interactive. Enabling background dragging here
        // causes terminal clicks and drag-to-select gestures to start moving the window.
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = nsBackgroundColor.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = nsBackgroundColor.cgColor
    }

    final class WindowObserverView: NSView {
        var windowTitle = ""
        var backgroundColor: Color = .clear

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfPossible()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyIfPossible()
        }

        func applyIfPossible() {
            guard let window else { return }
            MainWindowChromeBridge.configure(
                window,
                title: windowTitle,
                backgroundColor: backgroundColor
            )
        }
    }
}
#endif
