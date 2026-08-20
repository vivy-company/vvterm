#if os(macOS)
import SwiftUI
import AppKit

struct ZenWindowChromeBridge: NSViewRepresentable {
    @Binding var contentInsets: EdgeInsets

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [contentInsets = _contentInsets] window in
            guard let closeButton = window.standardWindowButton(.closeButton),
                  let miniButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton) else { return }

            let buttons = [closeButton, miniButton, zoomButton]
            buttons.forEach { button in
                button.isHidden = false
                button.alphaValue = 1
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
            }

            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let titlebarHeight = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )
            let newInsets = EdgeInsets(
                top: titlebarHeight,
                leading: safeArea.left,
                bottom: safeArea.bottom,
                trailing: safeArea.right
            )

            let currentInsets = contentInsets.wrappedValue
            let didChange =
                abs(currentInsets.top - newInsets.top) > 0.5 ||
                abs(currentInsets.leading - newInsets.leading) > 0.5 ||
                abs(currentInsets.bottom - newInsets.bottom) > 0.5 ||
                abs(currentInsets.trailing - newInsets.trailing) > 0.5

            if didChange {
                contentInsets.wrappedValue = newInsets
            }
        }
        nsView.triggerUpdate()
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.removeObservers()
    }

    final class WindowObserverView: NSView {
        var onWindowUpdate: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            triggerUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            triggerUpdate()
        }

        override func layout() {
            super.layout()
            triggerUpdate()
        }

        func triggerUpdate() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowUpdate?(window)
            }
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private func installObservers() {
            removeObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.triggerUpdate()
                    }
                }
            }
        }

        isolated deinit {
            removeObservers()
        }
    }
}

struct ToolbarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }
}

private struct TerminalCommandBridgeHost<Content: View>: View {
    @EnvironmentObject private var commandBridge: MacShellCommandBridge
    private let content: (MacShellCommandBridge) -> Content

    init(@ViewBuilder content: @escaping (MacShellCommandBridge) -> Content) {
        self.content = content
    }

    var body: some View {
        content(commandBridge)
    }
}

private struct TerminalZenChromeHost<Content: View>: View {
    let isZenModeEnabled: Bool
    let appliesTerminalInsets: Bool
    let backgroundColor: Color
    private let content: (EdgeInsets) -> Content

    @State private var safeAreaInsets = EdgeInsets()

    init(
        isZenModeEnabled: Bool,
        appliesTerminalInsets: Bool,
        backgroundColor: Color,
        @ViewBuilder content: @escaping (EdgeInsets) -> Content
    ) {
        self.isZenModeEnabled = isZenModeEnabled
        self.appliesTerminalInsets = appliesTerminalInsets
        self.backgroundColor = backgroundColor
        self.content = content
    }

    var body: some View {
        content(appliesTerminalInsets ? safeAreaInsets : EdgeInsets())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
            .overlay(alignment: .top) {
                if !isZenModeEnabled {
                    ToolbarBackdrop(color: backgroundColor)
                }
            }
            .background {
                if isZenModeEnabled {
                    ZenWindowChromeBridge(contentInsets: $safeAreaInsets)
                        .frame(width: 0, height: 0)
                }
            }
            .zenExpandedTopSafeArea(appliesTerminalInsets)
    }
}

extension ConnectionTerminalContainer {
    var platformBody: some View {
        TerminalCommandBridgeHost { commandBridge in
            sharedBody
                .focusedValue(\.openTerminalTab, handleNewTabCommand)
                .focusedValue(\.serverViewTabActions, serverViewTabActions())
                // The connected-server toolbar is rendered by the AppKit NSToolbar
                // (see MacConnectionToolbar). This pane publishes its sections into
                // the shared bridge; the toolbar hosts them.
                .onAppear { activateToolbarBridge(); updateCommandBridge(commandBridge) }
                .onDisappear {
                    MacToolbarBridge.shared.deactivate(ownerId: server.id.uuidString)
                    commandBridge.clear(ownerId: server.id.uuidString)
                }
                .onChange(of: selectedView) { _ in activateToolbarBridge(); updateCommandBridge(commandBridge) }
                .onChange(of: shouldShowViewPicker) { _ in activateToolbarBridge() }
                .onChange(of: serverTabs.count) { _ in activateToolbarBridge() }
                .onChange(of: serverFileTabs.count) { _ in activateToolbarBridge() }
                .onChange(of: selectedFileTabId) { _ in activateToolbarBridge() }
                .onChange(of: selectedTabId) { _ in activateToolbarBridge(); updateCommandBridge(commandBridge) }
                .onChange(of: selectedTab?.focusedPaneId) { _ in updateCommandBridge(commandBridge) }
                .onChange(of: selectedTab?.layout) { _ in updateCommandBridge(commandBridge) }
                .onChange(of: terminalContent.state.splitZoomedTabIds) { _ in updateCommandBridge(commandBridge) }
                .onChange(of: isZenModeEnabled) { _ in activateToolbarBridge() }
                .onChange(of: zenSubtitleText) { _ in activateToolbarBridge() }
                .onChange(of: toolbarFilesMenuEntries()) { _ in activateToolbarBridge() }
                .alert(
                    disconnectAlertTitle,
                    isPresented: $showingDisconnectConfirmation,
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button(disconnectActionTitle, role: .destructive) {
                        disconnectFromServer()
                    }
                    .keyboardShortcut(.defaultAction)
                } message: {
                    Text(disconnectAlertMessage)
                }
                .alert("Close this terminal?", isPresented: $showingPaneCloseConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Close", role: .destructive) {
                        closeFocusedPaneConfirmed()
                    }
                    .keyboardShortcut(.defaultAction)
                } message: {
                    Text("The SSH connection will be terminated.")
                }
                .sheet(item: $serverToEdit) { editingServer in
                    ServerFormSheet(
                        serverManager: serverManager,
                        workspace: serverManager.workspaces.first { $0.id == editingServer.workspaceId },
                        server: editingServer,
                        dependencies: serverFormDependencies,
                        makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                        onSave: { _ in
                            serverToEdit = nil
                        }
                    )
                    .adaptiveSoftScrollEdges()
                    .frame(
                        minWidth: 640,
                        idealWidth: 700,
                        maxWidth: 760,
                        minHeight: 520,
                        idealHeight: 620,
                        maxHeight: 680
                    )
                }
        }
    }

    /// Publishes this server's toolbar content to the AppKit toolbar bridge,
    /// which renders it with native controls.
    private func activateToolbarBridge() {
        let ownerId = server.id.uuidString
        let snapshot = MacToolbarSnapshot(
            ownerId: ownerId,
            showsViewPicker: shouldShowViewPicker,
            showsTabStrip: (selectedView == .terminal && !serverTabs.isEmpty)
                || (selectedView == .files && !serverFileTabs.isEmpty),
            showsFilesMenu: selectedView == .files,
            isZenMode: isZenModeEnabled,
            zenTitle: server.name,
            zenIcon: "server.rack",
            zenSubtitle: zenSubtitleText,
            viewPicker: toolbarViewPickerData(),
            filesMenu: toolbarFilesMenuEntries(),
            serverMenu: toolbarServerMenuEntries()
        )
        MacToolbarBridge.shared.activate(
            snapshot: snapshot,
            dispatch: performToolbarCommand,
            tabStrip: { tabsToolbarView },
            zenPanel: { zenPanelView }
        )
    }

    private func performToolbarCommand(_ command: MacToolbarCommandID) {
        switch command {
        case .selectView(let rawValue):
            guard let tab = ConnectionViewTabID(rawValue: rawValue) else { return }
            selectedViewBinding.wrappedValue = tab
        case .filesParent:
            guard let tab = selectedFileTab else { return }
            Task { await fileBrowser.goUp(in: tab, server: server) }
        case .filesRefresh:
            guard let tab = selectedFileTab else { return }
            Task { await fileBrowser.refresh(server: server, tab: tab) }
        case .filesUpload:
            guard let tab = selectedFileTab else { return }
            fileBrowser.requestUploadPicker(
                for: tab,
                destinationPath: fileBrowser.currentPath(for: tab)
            )
        case .filesNewFolder:
            guard let tab = selectedFileTab else { return }
            fileBrowser.requestCreateFolder(
                for: tab,
                destinationPath: fileBrowser.currentPath(for: tab)
            )
        case .filesToggleHidden:
            guard let tab = selectedFileTab else { return }
            fileBrowser.setShowHiddenFiles(!fileBrowser.showHiddenFiles(for: tab), for: tab)
        case .filesCopyPath:
            let path = selectedFileTab.map { fileBrowser.currentPath(for: $0) } ?? "/"
            Clipboard.copy(path)
        case .openSettings:
            onOpenSettings?()
        case .editServer:
            serverToEdit = server
        case .disconnect:
            showingDisconnectConfirmation = true
        case .enterZen:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isZenModeEnabled = true
            }
        }
    }

    /// Subtitle shown under the server name in zen, derived entirely from live
    /// in-memory state (no persistence / metadata mutation): the focused pane's
    /// runtime title for terminal, the current directory for files, otherwise
    /// the view's own name (e.g. Stats).
    private var zenSubtitleText: String {
        if selectedView == .files {
            guard let tab = selectedFileTab else { return "" }
            return fileBrowser.currentPath(for: tab)
        }
        if selectedView == .terminal {
            guard let selectedTab else { return "" }
            return tabManager.titleStore.displayTitle(for: selectedTab)
        }
        return String(localized: String.LocalizationValue(selectedView.localizedKey))
    }

    /// Publishes this server's keyboard-command actions to the command bridge,
    /// which ContentView republishes as scene focus values for the menu commands.
    private func updateCommandBridge(_ commandBridge: MacShellCommandBridge) {
        let splitActions: TerminalSplitActions?
        if selectedView == .terminal {
            splitActions = TerminalSplitActions(
                perform: performSplitCommand,
                isEnabled: { command in
                    guard let selectedTab else { return false }
                    return tabManager.canPerformSplitCommand(command, in: selectedTab)
                },
                isZoomed: {
                    guard let selectedTab else { return false }
                    return tabManager.isSplitZoomed(in: selectedTab)
                }
            )
        } else {
            splitActions = nil
        }

        commandBridge.update(
            ownerId: server.id.uuidString,
            serverViewTabActions: serverViewTabActions(),
            splitActions: splitActions,
            activeServerId: server.id,
            activePaneId: splitActions == nil ? nil : selectedTab?.focusedPaneId
        )
    }

    private func toolbarViewPickerData() -> ToolbarViewPickerData {
        ToolbarViewPickerData(
            segments: visibleViewTabs.map { tab in
                ToolbarViewPickerData.Segment(
                    id: tab.rawValue,
                    systemImage: tab.icon,
                    help: tab.rawValue.capitalized
                )
            },
            selectedId: selectedView.rawValue
        )
    }

    private func toolbarFilesMenuEntries() -> [ToolbarMenuEntry] {
        let tab = selectedFileTab
        let currentPath = tab.map { fileBrowser.currentPath(for: $0) } ?? "/"
        let hiddenVisible = tab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false
        let hasTab = tab != nil

        return [
            ToolbarMenuEntry(
                command: .filesParent,
                title: String(localized: "Parent"),
                systemImage: "arrow.turn.up.left",
                isEnabled: hasTab && currentPath != "/"
            ),
            ToolbarMenuEntry(
                command: .filesRefresh,
                title: String(localized: "Refresh"),
                systemImage: "arrow.clockwise",
                isEnabled: hasTab
            ),
            .separator,
            ToolbarMenuEntry(
                command: .filesUpload,
                title: String(localized: "Upload…"),
                systemImage: "square.and.arrow.up",
                isEnabled: hasTab
            ),
            ToolbarMenuEntry(
                command: .filesNewFolder,
                title: String(localized: "New Folder…"),
                systemImage: "folder.badge.plus",
                isEnabled: hasTab
            ),
            ToolbarMenuEntry(
                command: .filesToggleHidden,
                title: hiddenVisible ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files"),
                systemImage: hiddenVisible ? "eye.slash" : "eye",
                isEnabled: hasTab
            ),
            .separator,
            ToolbarMenuEntry(
                command: .filesCopyPath,
                title: String(localized: "Copy Path"),
                systemImage: "document.on.document"
            )
        ]
    }

    private func toolbarServerMenuEntries() -> [ToolbarMenuEntry] {
        [
            ToolbarMenuEntry(
                command: .openSettings,
                title: String(localized: "Settings"),
                systemImage: "gear"
            ),
            ToolbarMenuEntry(
                command: .editServer,
                title: String(localized: "Edit Server"),
                systemImage: "pencil"
            ),
            .separator,
            ToolbarMenuEntry(
                command: .disconnect,
                title: String(localized: "Disconnect"),
                systemImage: "xmark.circle",
                isDestructive: true
            )
        ]
    }

    @ViewBuilder
    private var tabsToolbarView: some View {
        if selectedView == .files {
            RemoteFileTabsScrollView(
                tabs: serverFileTabs,
                selectedTabId: selectedFileTabIdBinding,
                fileBrowser: fileBrowser,
                titleForTab: displayedFileTabTitle(for:),
                onSelect: { fileTabManager.selectTab($0) },
                onClose: { tab in
                    if let removedTab = fileTabManager.closeTab(tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                },
                onCloseOtherTabs: { tab in
                    for removedTab in fileTabManager.closeOtherTabs(except: tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                },
                onCloseTabsToLeft: { tab in
                    for removedTab in fileTabManager.closeTabsToLeft(of: tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                },
                onCloseTabsToRight: { tab in
                    for removedTab in fileTabManager.closeTabsToRight(of: tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                },
                onDuplicate: { tab in
                    guard fileTabManager.canOpenNewTab(
                        for: server.id,
                        hasProAccess: storeManager.allowsProFeatures
                    ) else {
                        showingFileTabLimitAlert = true
                        return
                    }

                    let seedPath = fileBrowser.lastVisitedPath(for: tab)
                    guard let duplicate = fileTabManager.duplicateTab(
                        tab,
                        seedPath: seedPath,
                        hasProAccess: storeManager.allowsProFeatures
                    ) else { return }
                    fileBrowser.prepareNewTab(duplicate, duplicating: tab)
                },
                onNew: { openNewFileTab(selectFilesViewOnSuccess: false) }
            )
        } else {
            TerminalTabsScrollView(
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                onClose: { tab in tabManager.closeTab(tab) },
                onNew: { openNewTab() },
                projection: terminalToolbarProjection.tabStrip
            )
        }
    }

    /// The rich Zen controls panel, hosted inside the native zen toolbar
    /// button's menu (NSMenuItem.view) so we get a native circle button AND the
    /// full panel.
    private var zenPanelView: some View {
        ZenModePanel(
            width: 360,
            serverName: server.name,
            statusText: tabsStatusText,
            statusColor: zenIndicatorColor,
            selectedView: selectedView,
            selectedViewBinding: selectedViewBinding,
            viewTabs: visibleViewTabs,
            terminalTabs: serverTabs,
            selectedTerminalTabId: selectedTabIdBinding,
            terminalTabTitle: { tabManager.titleStore.displayTitle(for: $0) },
            paneState: { tab in
                tabManager.sessionState.paneState(for: tab.focusedPaneId)
            },
            fileTabs: serverFileTabs,
            selectedFileTabId: selectedFileTabIdBinding,
            fileTabTitle: displayedFileTabTitle(for:),
            onPreviousTab: {
                if selectedView == .files {
                    selectPreviousFileTab()
                } else {
                    selectPreviousTab()
                }
            },
            onNextTab: {
                if selectedView == .files {
                    selectNextFileTab()
                } else {
                    selectNextTab()
                }
            },
            onNewTerminalTab: {
                showingZenPanel = false
                openNewTab(selectTerminalViewOnSuccess: true)
            },
            onCloseTerminalTab: { tab in
                tabManager.closeTab(tab)
            },
            onNewFileTab: {
                showingZenPanel = false
                openNewFileTab(selectFilesViewOnSuccess: true)
            },
            onCloseFileTab: { tab in
                if let removedTab = fileTabManager.closeTab(tab) {
                    fileBrowser.removeState(for: removedTab.id)
                }
            },
            onSelectFileTab: { tab in
                fileTabManager.selectTab(tab)
            },
            onSplitRight: {
                splitFocusedPane(.right)
            },
            onSplitDown: {
                splitFocusedPane(.down)
            },
            onClosePane: { requestCloseFocusedPane() },
            canSplit: selectedTab != nil,
            canClosePane: selectedTab != nil,
            isSidebarVisible: isSidebarVisible,
            onToggleSidebar: {
                showingZenPanel = false
                onToggleSidebar()
            },
            onDisconnect: {
                showingZenPanel = false
                showingDisconnectConfirmation = true
            },
            canFilesGoUp: selectedFileTab.map { fileBrowser.currentPath(for: $0) != "/" } ?? false,
            filesShowHiddenBinding: Binding(
                get: { selectedFileTab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false },
                set: { newValue in
                    guard let selectedFileTab else { return }
                    fileBrowser.setShowHiddenFiles(newValue, for: selectedFileTab)
                }
            ),
            onFilesGoUp: {
                guard let selectedFileTab else { return }
                Task { await fileBrowser.goUp(in: selectedFileTab, server: server) }
            },
            onFilesRefresh: {
                guard let selectedFileTab else { return }
                Task { await fileBrowser.refresh(server: server, tab: selectedFileTab) }
            },
            onExitZen: {
                showingZenPanel = false
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isZenModeEnabled = false
                }
            }
        )
        .adaptiveSoftScrollEdges()
        .frame(width: 360)
    }

    private func disconnectFromServer() {
        statsDependencies.runtimeStore.releaseCollector(for: server.id)
        fileBrowser.disconnect(serverId: server.id)
        fileTabManager.disconnect(serverId: server.id)
        tabManager.disconnectServer(server.id)
    }

    private func splitFocusedPane(_ placement: TerminalSplitPlacement) {
        guard let selectedTab else { return }
        guard storeManager.allowsProFeatures else {
            showingZenPanel = false
            showingSplitPaneUpgradeAlert = true
            return
        }

        switch placement {
        case .right:
            _ = tabManager.splitRight(
                tab: selectedTab,
                paneId: selectedTab.focusedPaneId,
                hasProAccess: storeManager.allowsProFeatures
            )
        case .left:
            _ = tabManager.splitLeft(
                tab: selectedTab,
                paneId: selectedTab.focusedPaneId,
                hasProAccess: storeManager.allowsProFeatures
            )
        case .down:
            _ = tabManager.splitDown(
                tab: selectedTab,
                paneId: selectedTab.focusedPaneId,
                hasProAccess: storeManager.allowsProFeatures
            )
        case .up:
            _ = tabManager.splitUp(
                tab: selectedTab,
                paneId: selectedTab.focusedPaneId,
                hasProAccess: storeManager.allowsProFeatures
            )
        }
    }

    private func performSplitCommand(_ command: TerminalSplitCommand) {
        guard let selectedTab else { return }
        switch tabManager.performSplitCommand(
            command,
            in: selectedTab,
            hasProAccess: storeManager.allowsProFeatures
        ) {
        case .performed, .unavailable:
            break
        case .requiresUpgrade:
            showingZenPanel = false
            showingSplitPaneUpgradeAlert = true
        case .requiresCloseConfirmation:
            requestCloseFocusedPane()
        }
    }

    private var zenIndicatorColor: Color {
        guard let state = selectedTab.flatMap({
            tabManager.sessionState.paneState(for: $0.focusedPaneId)
        }) else {
            if selectedView == .files {
                return serverFileTabs.isEmpty ? .secondary : .green
            }
            return serverTabs.isEmpty ? .secondary : .green
        }

        switch state.connectionState {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected, .idle:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var tabsStatusText: String {
        let count = selectedView == .files ? serverFileTabs.count : serverTabs.count

        if selectedView == .files {
            if count == 0 {
                return String(localized: "No file tabs")
            }

            return count == 1
                ? String(localized: "1 file tab")
                : String(format: String(localized: "%lld file tabs"), Int64(count))
        }

        if count == 0 {
            return String(localized: "No terminals")
        }

        return count == 1
            ? String(localized: "1 tab")
            : String(format: String(localized: "%lld tabs"), Int64(count))
    }

    private var compactTabsStatusText: String {
        let count = selectedView == .files ? serverFileTabs.count : serverTabs.count

        if selectedView == .files {
            return count == 1
                ? String(localized: "1 file tab")
                : String(format: String(localized: "%lld file tabs"), Int64(count))
        }

        return count == 1
            ? String(localized: "1 tab")
            : String(format: String(localized: "%lld tabs"), Int64(count))
    }

    private var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    private var disconnectActionTitle: String {
        String(localized: "Close")
    }

    private var disconnectAlertMessage: String {
        let terminalCount = serverTabs.count
        let fileCount = serverFileTabs.count

        if terminalCount == 0, fileCount == 0 {
            return String(localized: "This will return to the server list.")
        }

        if terminalCount > 0, fileCount > 0 {
            return String(localized: "All terminal and file tabs for this server will be closed.")
        }

        if fileCount > 0 {
            return String(localized: "All file tabs for this server will be closed.")
        }

        return String(localized: "All terminal tabs for this server will be closed.")
    }

    func platformChrome(backgroundColor: Color) -> some View {
        TerminalZenChromeHost(
            isZenModeEnabled: isZenModeEnabled,
            appliesTerminalInsets: isZenModeEnabled && selectedView == .terminal,
            backgroundColor: backgroundColor
        ) { terminalContentInsets in
            ZStack {
                statsLayer(backgroundColor: backgroundColor)

                if selectedView == .files {
                    filesLayer
                }

                terminalLayer(contentInsets: terminalContentInsets)
            }
        }
    }

    @ViewBuilder
    private func statsLayer(backgroundColor: Color) -> some View {
        if selectedView == .stats {
            ServerStatsView(
                server: server,
                backgroundColor: backgroundColor,
                sharedClientProvider: { tabManager.transportCoordinator.sharedStatsClient(for: server.id) },
                dependencies: statsDependencies,
                isDockerUnlocked: storeManager.allowsProFeatures
            )
            .zIndex(1)
        }
    }

    @ViewBuilder
    private func terminalLayer(contentInsets: EdgeInsets) -> some View {
        ForEach(serverTabs, id: \.id) { tab in
            let isVisible = selectedView == .terminal && selectedTabId == tab.id
            let voiceRuntime = voiceInputRuntimeStore.runtime(for: tab.id)
            TerminalTabView(
                tab: tab,
                server: server,
                tabManager: tabManager,
                securityActions: terminalSecurityActions,
                isSelected: isVisible,
                isSplitZoomed: terminalContent.state.splitZoomedTabIds.contains(tab.id),
                appearance: terminalAppearanceSnapshot,
                voiceSettingsStore: voiceInputRuntimeStore.settingsStore,
                audioService: voiceRuntime.audioService,
                voiceRecordingOperation: voiceRuntime.recordingOperation
            )
            .padding(contentInsets)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .zIndex(isVisible ? 1 : 0)
        }

        if selectedView == .terminal && serverTabs.isEmpty {
            TerminalEmptyStateView(server: server) {
                openNewTab()
            }
            .padding(contentInsets)
        }
    }

    func platformHandleSelectedViewChange(_ selectedView: ConnectionViewTabID) {}

    func platformPrepareForPaneClose() {}
}

private extension View {
    @ViewBuilder
    func zenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        if isEnabled {
            self.ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
    }
}
#endif
