//
//  ConnectionTabsView.swift
//  VVTerm
//

import SwiftUI

struct TerminalServerToolbarProjectionHost<Content: View>: View {
    @StateObject private var projection: TerminalServerToolbarProjection
    private let content: (TerminalServerToolbarProjection) -> Content

    init(
        serverId: UUID,
        tabManager: TerminalTabManager,
        @ViewBuilder content: @escaping (TerminalServerToolbarProjection) -> Content
    ) {
        _projection = StateObject(
            wrappedValue: TerminalServerToolbarProjection(
                serverId: serverId,
                tabManager: tabManager
            )
        )
        self.content = content
    }

    var body: some View {
        content(projection)
    }
}

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    let tabManager: TerminalTabManager
    let terminalToolbarProjection: TerminalServerToolbarProjection
    @ObservedObject var terminalContent: TerminalServerContentProjection
    @ObservedObject private var tmuxCoordinator: TerminalTmuxSessionCoordinator
    @ObservedObject var fileTabManager: RemoteFileTabManager
    let serverManager: ServerManager
    let fileBrowser: RemoteFileBrowserStore
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    let statsDependencies: ServerStatsScreenDependencies
    let terminalSecurityActions: TerminalSecurityActions
    let serverFormDependencies: ServerFormDependencies
    let voiceInputRuntimeStore: VoiceInputRuntimeStore
    let server: Server
    @Binding var isZenModeEnabled: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onOpenSettings: (() -> Void)?
    let onLeaveRoute: (() -> Void)?
    let onDisconnectRoute: (() -> Void)?

    @EnvironmentObject var ghosttyApp: GhosttyRuntime
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager

    /// Disconnect confirmation
    @State var showingDisconnectConfirmation = false
    /// Confirmation before closing the focused split pane via a command/panel
    /// (the in-pane close button has its own confirmation in TerminalTabView).
    @State var showingPaneCloseConfirmation = false
    @State var serverToEdit: Server?

    /// Tab limit alert
    @State private var showingTabLimitAlert = false
    @State var showingFileTabLimitAlert = false
    @State var showingSplitPaneUpgradeAlert = false
    @State var showingZenPanel = false

    init(
        tabManager: TerminalTabManager,
        terminalToolbarProjection: TerminalServerToolbarProjection,
        fileTabManager: RemoteFileTabManager,
        serverManager: ServerManager,
        fileBrowser: RemoteFileBrowserStore,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        statsDependencies: ServerStatsScreenDependencies,
        terminalSecurityActions: TerminalSecurityActions,
        serverFormDependencies: ServerFormDependencies,
        voiceInputRuntimeStore: VoiceInputRuntimeStore,
        server: Server,
        isZenModeEnabled: Binding<Bool>,
        isSidebarVisible: Bool,
        onToggleSidebar: @escaping () -> Void,
        onOpenSettings: (() -> Void)?,
        onLeaveRoute: (() -> Void)?,
        onDisconnectRoute: (() -> Void)?
    ) {
        self.tabManager = tabManager
        self.terminalToolbarProjection = terminalToolbarProjection
        _terminalContent = ObservedObject(wrappedValue: terminalToolbarProjection.content)
        _tmuxCoordinator = ObservedObject(wrappedValue: tabManager.tmuxCoordinator)
        self.fileTabManager = fileTabManager
        self.serverManager = serverManager
        self.fileBrowser = fileBrowser
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.statsDependencies = statsDependencies
        self.terminalSecurityActions = terminalSecurityActions
        self.serverFormDependencies = serverFormDependencies
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.server = server
        _isZenModeEnabled = isZenModeEnabled
        self.isSidebarVisible = isSidebarVisible
        self.onToggleSidebar = onToggleSidebar
        self.onOpenSettings = onOpenSettings
        self.onLeaveRoute = onLeaveRoute
        self.onDisconnectRoute = onDisconnectRoute
    }

    /// Selected view type - persisted per server
    var selectedView: ConnectionViewTabID {
        viewTabConfig.effectiveView(
            for: terminalContent.state.selectedView
        )
    }

    var visibleViewTabs: [ConnectionViewTabID] {
        viewTabConfig.currentVisibleTabs
    }

    var shouldShowViewPicker: Bool {
        visibleViewTabs.count > 1
    }

    var terminalAppearance: TerminalColorAppearance {
        colorScheme == .dark ? .dark : .light
    }

    var terminalAppearanceSnapshot: TerminalAppearanceSnapshot {
        terminalThemeManager.appearanceSnapshot(for: terminalAppearance)
    }

    var selectedViewBinding: Binding<ConnectionViewTabID> {
        Binding(
            get: {
                viewTabConfig.effectiveView(
                    for: terminalContent.state.selectedView
                )
            },
            set: { newValue in
                let current = viewTabConfig.effectiveView(
                    for: tabManager.connectionViewSelections.selection(for: server.id)
                )
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.sessionState.selectView(
                        viewTabConfig.effectiveView(for: newValue),
                        for: server.id
                    )
                }
            }
        )
    }

    /// Tabs for THIS server only
    var serverTabs: [TerminalTab] {
        terminalContent.state.tabs
    }

    /// Effective selected tab ID for this server.
    var selectedTabId: UUID? {
        if let selectedId = terminalContent.state.selectedTabId,
           serverTabs.contains(where: { $0.id == selectedId }) {
            return selectedId
        }
        return serverTabs.first?.id
    }

    var selectedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedTabId },
            set: { newValue in
                let validId = newValue.flatMap { requestedId in
                    serverTabs.contains(where: { $0.id == requestedId }) ? requestedId : serverTabs.first?.id
                }
                guard tabManager.sessionState.selectedTabId(for: server.id) != validId else { return }
                tabManager.sessionState.selectTab(validId, for: server.id)
            }
        )
    }

    /// Currently selected tab
    var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return serverTabs.first }
        return serverTabs.first { $0.id == id } ?? serverTabs.first
    }

    var serverFileTabs: [RemoteFileTab] {
        fileTabManager.tabs(for: server.id)
    }

    var selectedFileTabId: UUID? {
        fileTabManager.selectedTab(for: server.id)?.id
    }

    var selectedFileTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedFileTabId },
            set: { newValue in
                guard let newValue,
                      let tab = serverFileTabs.first(where: { $0.id == newValue }) else {
                    return
                }
                DispatchQueue.main.async {
                    fileTabManager.selectTab(tab)
                }
            }
        )
    }

    var selectedFileTab: RemoteFileTab? {
        fileTabManager.selectedTab(for: server.id)
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = tmuxCoordinator.attachPrompt else { return nil }
                guard tabManager.sessionState.paneState(for: prompt.paneId)?.serverId == server.id else { return nil }
                return prompt
            },
            set: { newValue in
                guard newValue == nil,
                      let prompt = tmuxCoordinator.attachPrompt else { return }
                guard tabManager.sessionState.paneState(for: prompt.paneId)?.serverId == server.id else { return }
                tmuxCoordinator.cancelPrompt(requestId: prompt.id)
            }
        )
    }

    private var liveTerminalBackgroundColor: Color {
        Color.fromHex(terminalAppearanceSnapshot.activeTheme.palette.backgroundHex)
    }

    var sharedBody: some View {
        let backgroundColor = liveTerminalBackgroundColor

        return platformChrome(backgroundColor: backgroundColor)
            .onAppear {
                voiceInputRuntimeStore.synchronize(
                    tabIDs: Set(serverTabs.map(\.id)),
                    for: server.id
                )
                repairSelectedTabSelectionIfNeeded()
                platformHandleSelectedViewChange(selectedView)
                ensureInitialFileTabIfNeeded()
            }
            .task(id: terminalAppearanceSnapshot) {
                let snapshot = terminalThemeManager.activateAppearance(terminalAppearance)
                ghosttyApp.applyAppearance(snapshot)
            }
            .onChange(of: selectedView) { newValue in
                platformHandleSelectedViewChange(newValue)
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: serverTabs.map(\.id)) { tabIDs in
                voiceInputRuntimeStore.synchronize(
                    tabIDs: Set(tabIDs),
                    for: server.id
                )
                repairSelectedTabSelectionIfNeeded()
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if !newValue {
                    showingZenPanel = false
                }
            }
            .onDisappear {
                statsDependencies.runtimeStore.releaseCollector(for: server.id)
            }
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
    }

    @ViewBuilder
    var filesLayer: some View {
        if let selectedFileTab {
            RemoteFileBrowserScreen(
                browser: fileBrowser,
                server: server,
                fileTab: selectedFileTab,
                appearance: terminalAppearanceSnapshot,
                initialPath: selectedFileTab.seedPath
            ) { currentPath in
                fileTabManager.updateLastKnownPath(currentPath, for: selectedFileTab.id)
            }
            .id(selectedFileTab.id)
            .zIndex(1)
        } else {
            RemoteFileTabsEmptyState(server: server) {
                openNewFileTab(selectFilesViewOnSuccess: false)
            }
            .zIndex(1)
        }
    }

    var body: some View {
        platformBody
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        tabManager.tmuxCoordinator.resolvePrompt(
                            requestId: prompt.id,
                            selection: selection
                        )
                    }
                )
                .adaptiveSoftScrollEdges()
            }
    }

    func handleNewTabCommand() {
        if selectedView == .files {
            openNewFileTab(selectFilesViewOnSuccess: true)
        } else {
            openNewTab(selectTerminalViewOnSuccess: true)
        }
    }

    private func ensureInitialFileTabIfNeeded() {
        guard selectedView == .files else { return }

        let seedPath = selectedTab.flatMap {
            tabManager.sessionState.paneState(for: $0.focusedPaneId)?.workingDirectory
        }
        DispatchQueue.main.async {
            guard selectedView == .files else { return }
            guard let fileTab = fileTabManager.ensureInitialTab(
                for: server,
                seedPath: seedPath,
                hasProAccess: storeManager.allowsProFeatures
            ) else { return }
            fileBrowser.prepareNewTab(fileTab, duplicating: nil)
        }
    }

    private func repairSelectedTabSelectionIfNeeded() {
        let currentId = tabManager.sessionState.selectedTabId(for: server.id)
        let repairedId = selectedTabId
        guard currentId != repairedId else { return }
        tabManager.sessionState.selectTab(repairedId, for: server.id)
    }

    func openNewTab(selectTerminalViewOnSuccess: Bool = false) {
        guard tabManager.sessionState.canOpenNewTab(hasProAccess: storeManager.allowsProFeatures) else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    if selectTerminalViewOnSuccess {
                        tabManager.sessionState.selectView(
                            viewTabConfig.effectiveView(for: .terminal),
                            for: server.id
                        )
                    }
                    selectedTabIdBinding.wrappedValue = tab.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    func openNewFileTab(selectFilesViewOnSuccess: Bool = false) {
        guard fileTabManager.canOpenNewTab(
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
            fileTabManager.duplicateTab(
                $0,
                seedPath: seedPath,
                hasProAccess: storeManager.allowsProFeatures
            )
        } ?? fileTabManager.openTab(
            for: server,
            seedPath: seedPath,
            hasProAccess: storeManager.allowsProFeatures
        )

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: sourceTab)

        if selectFilesViewOnSuccess {
            tabManager.sessionState.selectView(
                viewTabConfig.effectiveView(for: .files),
                for: server.id
            )
        }
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex - 1].id
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < serverTabs.count - 1 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex + 1].id
    }

    func selectPreviousFileTab() {
        fileTabManager.selectPreviousTab(for: server.id)
    }

    func selectNextFileTab() {
        fileTabManager.selectNextTab(for: server.id)
    }

    private func baseFileTabTitle(for tab: RemoteFileTab) -> String {
        let candidatePath = fileBrowser.lastVisitedPath(for: tab)
            ?? tab.lastKnownPath
            ?? tab.seedPath

        guard let candidatePath else {
            return server.name.nonEmptyString ?? "/"
        }

        let normalizedPath = RemoteFilePath.normalize(candidatePath)
        guard normalizedPath != "/" else {
            return server.name.nonEmptyString ?? "/"
        }

        return RemoteFilePath.breadcrumbs(for: normalizedPath).last?.title ?? (server.name.nonEmptyString ?? "/")
    }

    func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let baseTitles = Dictionary(
            uniqueKeysWithValues: serverFileTabs.map { ($0.id, baseFileTabTitle(for: $0)) }
        )
        let titleCounts = Dictionary(grouping: baseTitles.values, by: { $0 }).mapValues(\.count)
        var seenCounts: [String: Int] = [:]
        var resolvedTitles: [UUID: String] = [:]

        for tab in serverFileTabs {
            let baseTitle = baseTitles[tab.id] ?? (server.name.nonEmptyString ?? "/")
            guard (titleCounts[baseTitle] ?? 0) > 1 else {
                resolvedTitles[tab.id] = baseTitle
                continue
            }

            seenCounts[baseTitle, default: 0] += 1
            resolvedTitles[tab.id] = "\(baseTitle) (\(seenCounts[baseTitle, default: 0]))"
        }

        return resolvedTitles[tab.id] ?? baseFileTabTitle(for: tab)
    }

    private func closeSelectedFileTab() {
        guard let selectedFileTab,
              let removedTab = fileTabManager.closeTab(selectedFileTab) else {
            return
        }
        fileBrowser.removeState(for: removedTab.id)
    }

    func serverViewTabActions() -> ServerViewTabActions {
        ServerViewTabActions(
            openNew: handleNewTabCommand,
            closeSelected: {
                if selectedView == .files {
                    closeSelectedFileTab()
                } else if let selectedTab {
                    // Close the focused split pane first (with confirmation,
                    // since it terminates an SSH connection); only close the
                    // whole tab once it's the last remaining pane.
                    if selectedTab.paneCount > 1 {
                        requestCloseFocusedPane()
                    } else {
                        tabManager.closeTab(selectedTab)
                    }
                }
            },
            selectPrevious: {
                if selectedView == .files {
                    selectPreviousFileTab()
                } else {
                    selectPreviousTab()
                }
            },
            selectNext: {
                if selectedView == .files {
                    selectNextFileTab()
                } else {
                    selectNextTab()
                }
            },
            selectIndex: { index in
                if selectedView == .files {
                    selectFileTab(at: index)
                } else {
                    selectTab(at: index)
                }
            }
        )
    }

    private func selectTab(at index: Int) {
        guard serverTabs.indices.contains(index) else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[index].id
    }

    private func selectFileTab(at index: Int) {
        guard serverFileTabs.indices.contains(index) else { return }
        fileTabManager.selectTab(serverFileTabs[index])
    }

    /// Ask before closing the focused pane (terminates its SSH connection),
    /// matching the in-pane close button's confirmation.
    func requestCloseFocusedPane() {
        guard selectedTab != nil else { return }
        platformPrepareForPaneClose()
        showingPaneCloseConfirmation = true
    }

    func closeFocusedPaneConfirmed() {
        guard let selectedTab else { return }
        tabManager.closePane(tab: selectedTab, paneId: selectedTab.focusedPaneId)
    }

}
