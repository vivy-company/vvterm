//
//  ConnectionTabsView.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    @ObservedObject var tabManager: TerminalTabManager
    let serverManager: ServerManager
    let fileBrowser: RemoteFileBrowserStore
    let server: Server
    @Binding var isZenModeEnabled: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared

    /// Theme name from settings
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    /// Disconnect confirmation
    @State private var showingDisconnectConfirmation = false
    @State private var serverToEdit: Server?

    /// Tab limit alert
    @State private var showingTabLimitAlert = false
    @State private var showingSplitPaneUpgradeAlert = false
    @State private var showingZenPanel = false
    #if os(macOS)
    @State private var zenWindowSafeAreaInsets = EdgeInsets()
    @State private var hostingWindow: NSWindow?
    #endif

    /// Selected view type - persisted per server
    private var selectedView: String {
        viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
    }

    private var visibleViewTabs: [ConnectionViewTab] {
        viewTabConfig.currentVisibleTabs
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var selectedViewBinding: Binding<String> {
        Binding(
            get: { viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id]) },
            set: { newValue in
                let current = viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(newValue)
                        ? newValue
                        : viewTabConfig.effectiveDefaultTab()
                }
            }
        )
    }

    /// Tabs for THIS server only
    private var serverTabs: [TerminalTab] {
        tabManager.tabs(for: server.id)
    }

    /// Selected tab ID for this server
    private var selectedTabId: UUID? {
        tabManager.selectedTabByServer[server.id]
    }

    private var selectedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { tabManager.selectedTabByServer[server.id] },
            set: { newValue in
                let current = tabManager.selectedTabByServer[server.id]
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedTabByServer[server.id] = newValue
                }
            }
        )
    }

    /// Currently selected tab
    private var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return serverTabs.first }
        return serverTabs.first { $0.id == id } ?? serverTabs.first
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = tabManager.tmuxAttachPrompt else { return nil }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return nil }
                return prompt
            },
            set: { newValue in
                guard newValue == nil, let prompt = tabManager.tmuxAttachPrompt else { return }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return }
                tabManager.cancelTmuxAttachPrompt(paneId: prompt.id)
            }
        )
    }

    private var macOSZenTerminalContentInsets: EdgeInsets {
        #if os(macOS)
        return isZenModeEnabled ? zenWindowSafeAreaInsets : EdgeInsets()
        #else
        return EdgeInsets()
        #endif
    }

    private var liveTerminalBackgroundColor: Color {
        ThemeColorParser.backgroundColor(for: effectiveThemeName)!
    }

    private var sharedBody: some View {
        contentLayer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(liveTerminalBackgroundColor)
            .overlay(alignment: .top) {
                #if os(macOS)
                if !isZenModeEnabled {
                    MacOSToolbarBackdrop(color: liveTerminalBackgroundColor)
                }
                #endif
            }
            .background {
                #if os(macOS)
                if isZenModeEnabled {
                    MacOSZenWindowChromeBridge(contentInsets: $zenWindowSafeAreaInsets)
                        .frame(width: 0, height: 0)
                }
                HostingWindowObserver(window: $hostingWindow)
                    .frame(width: 0, height: 0)
                #endif
            }
            .macOSZenExpandedTopSafeArea(isZenModeEnabled && selectedView == "terminal")
            .onAppear {
                updateTerminalBackgroundColor()
                // Select first tab if none selected
                if selectedTabId == nil {
                    selectedTabIdBinding.wrappedValue = serverTabs.first?.id
                }
            }
            .onChange(of: terminalThemeName) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: terminalThemeNameLight) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: usePerAppearanceTheme) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: colorScheme) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: serverTabs.count) { _ in
                // Auto-select if current selection is invalid
                if let currentId = selectedTabId, !serverTabs.contains(where: { $0.id == currentId }) {
                    selectedTabIdBinding.wrappedValue = serverTabs.first?.id
                }
                if selectedView != "terminal" || serverTabs.isEmpty {
                    clearTerminalFocusIfNeeded()
                }
            }
            .onChange(of: selectedView) { newValue in
                guard newValue != "terminal" else { return }
                clearTerminalFocusIfNeeded()
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if !newValue {
                    showingZenPanel = false
                }
            }
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        tabManager.resolveTmuxAttachPrompt(paneId: prompt.id, selection: selection)
                    }
                )
            }
    }

    @ViewBuilder
    private var contentLayer: some View {
        ZStack {
            // Stats view - always in hierarchy, visibility controlled by opacity
            // Pass isVisible to pause/resume collection when hidden
            ServerStatsView(
                server: server,
                isVisible: selectedView == "stats",
                backgroundColor: liveTerminalBackgroundColor,
                sharedClientProvider: { tabManager.sharedStatsClient(for: server.id) },
                statsCollector: ServerStatsCollector()
            )
                .opacity(selectedView == "stats" ? 1 : 0)
                .allowsHitTesting(selectedView == "stats")
                .zIndex(selectedView == "stats" ? 1 : 0)

            if selectedView == "files" {
                RemoteFileBrowserScreen(
                    browser: fileBrowser,
                    server: server,
                    initialPath: selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
                )
                    .zIndex(1)
            }

            #if os(macOS)
            // Each tab is an isolated terminal view
            ForEach(serverTabs, id: \.id) { tab in
                let isVisible = selectedView == "terminal" && selectedTabId == tab.id
                TerminalTabView(
                    tab: tab,
                    server: server,
                    tabManager: tabManager,
                    isSelected: isVisible
                )
                .padding(macOSZenTerminalContentInsets)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .zIndex(isVisible ? 1 : 0)
            }

            // Empty state when in terminal view with no tabs
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
                .padding(macOSZenTerminalContentInsets)
            }
            #else
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
            }
            #endif
        }
    }

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        sharedBody
        #endif
    }

    private func handleNewTabCommand() {
        openNewTab(selectTerminalViewOnSuccess: true)
    }

    private func openNewTab(selectTerminalViewOnSuccess: Bool = false) {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }

        Task {
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    if selectTerminalViewOnSuccess {
                        tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id)
                            ? ConnectionViewTab.terminal.id
                            : viewTabConfig.effectiveDefaultTab()
                    }
                    selectedTabIdBinding.wrappedValue = tab.id
                }
            } catch {
                // No-op: user cancelled biometric auth or open failed.
            }
        }
    }

    private func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex - 1].id
    }

    private func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < serverTabs.count - 1 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex + 1].id
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)!
            await MainActor.run {
                UserDefaults.standard.set(resolved.toHex(), forKey: "terminalBackgroundColor")
            }
        }
    }

    private func clearTerminalFocusIfNeeded() {
        #if os(macOS)
        let serverId = server.id
        DispatchQueue.main.async {
            guard TerminalTabManager.shared.selectedViewByServer[serverId] != "terminal" else { return }
            guard let window = hostingWindow,
                  window.firstResponder is GhosttyTerminalView else { return }
            window.makeFirstResponder(nil)
        }
        #endif
    }

    // MARK: - Toolbar Items (macOS)

    #if os(macOS)
    private var macOSBody: some View {
        sharedBody
            .focusedValue(\.openTerminalTab, handleNewTabCommand)
            .toolbar {
                if !isZenModeEnabled {
                    viewPickerToolbarItem
                    if selectedView == "terminal" && !serverTabs.isEmpty {
                        tabsToolbarSpacer
                        tabsToolbarItem
                    }
                    toolbarSpacer
                    trailingToolbarItems
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        zenModePanelToolbarButton
                    }
                }
            }
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
            .sheet(item: $serverToEdit) { editingServer in
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: serverManager.workspaces.first { $0.id == editingServer.workspaceId },
                    server: editingServer,
                    onSave: { _ in
                        serverToEdit = nil
                    }
                )
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

    @ToolbarContentBuilder
    private var viewPickerToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            viewPickerControl
        }
    }

    private var viewPickerControl: some View {
        Picker("View", selection: selectedViewBinding) {
            ForEach(visibleViewTabs) { tab in
                Label(tab.localizedKey, systemImage: tab.icon)
                    .tag(tab.id)
            }
        }
        .pickerStyle(.segmented)
    }

    @ToolbarContentBuilder
    private var tabsToolbarSpacer: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .navigation)
        } else {
            ToolbarItem(placement: .navigation) {
                Color.clear
                    .frame(width: 8, height: 1)
            }
        }
    }

    @ToolbarContentBuilder
    private var tabsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TerminalTabsScrollView(
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                onClose: { tab in tabManager.closeTab(tab) },
                onNew: { openNewTab() },
                tabManager: tabManager
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarSpacer: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        if selectedView == "files" {
            ToolbarItem(placement: .primaryAction) {
                filesActionsToolbarButton
            }
        }

        ToolbarItem(placement: .primaryAction) {
            zenModeToolbarButton
        }

        ToolbarItem(placement: .primaryAction) {
            serverMenuToolbarButton
        }
    }

    private var zenModeToolbarButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isZenModeEnabled = true
            }
        } label: {
            Label("Zen", systemImage: "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
        }
        .help(Text("Enter Zen Mode"))
    }

    private var filesActionsToolbarButton: some View {
        let currentPath = fileBrowser.currentPath(for: server.id)
        let areHiddenFilesVisible = fileBrowser.showHiddenFiles(for: server.id)

        return Menu {
            Button {
                Task { await fileBrowser.goUp(server: server) }
            } label: {
                Label("Parent", systemImage: "arrow.turn.up.left")
            }
            .disabled(currentPath == "/")

            Button {
                Task { await fileBrowser.refresh(server: server) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                fileBrowser.requestUploadPicker(for: server.id, destinationPath: currentPath)
            } label: {
                Label("Upload…", systemImage: "square.and.arrow.up")
            }

            Button {
                fileBrowser.requestCreateFolder(for: server.id, destinationPath: currentPath)
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }

            Button {
                fileBrowser.setShowHiddenFiles(!areHiddenFilesVisible, serverId: server.id)
            } label: {
                Label(
                    areHiddenFilesVisible ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: areHiddenFilesVisible ? "eye.slash" : "eye"
                )
            }

            Divider()

            Button {
                Clipboard.copy(currentPath)
            } label: {
                Label("Copy Path", systemImage: "document.on.document")
            }
        } label: {
            Label("Files", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .help(Text("Files Menu"))
    }

    private var serverMenuToolbarButton: some View {
        Menu {
            Button {
                SettingsWindowManager.shared.show()
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                serverToEdit = server
            } label: {
                Label("Edit Server", systemImage: "pencil")
            }

            Button(role: .destructive) {
                showingDisconnectConfirmation = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } label: {
            Label("Server", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(Text("Server Options"))
    }

    private var zenModePanelToolbarButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                showingZenPanel.toggle()
            }
        } label: {
            Label("Zen", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
        }
        .help(Text(showingZenPanel ? "Hide Zen controls" : "Show Zen controls"))
        .popover(isPresented: $showingZenPanel, arrowEdge: .top) {
            MacOSZenModePanel(
                width: 360,
                serverName: server.name,
                statusText: tabsStatusText,
                statusColor: zenIndicatorColor,
                selectedView: selectedView,
                selectedViewBinding: selectedViewBinding,
                viewTabs: visibleViewTabs,
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                paneState: { tab in
                    tabManager.paneStates[tab.focusedPaneId]
                },
                onPreviousTab: { selectPreviousTab() },
                onNextTab: { selectNextTab() },
                onNewTab: {
                    showingZenPanel = false
                    openNewTab(selectTerminalViewOnSuccess: true)
                },
                onCloseTab: { tab in
                    tabManager.closeTab(tab)
                },
                onSplitRight: {
                    splitFocusedPane(.horizontal)
                },
                onSplitDown: {
                    splitFocusedPane(.vertical)
                },
                onClosePane: {
                    guard let selectedTab else { return }
                    tabManager.closePane(tab: selectedTab, paneId: selectedTab.focusedPaneId)
                },
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
                canFilesGoUp: fileBrowser.currentPath(for: server.id) != "/",
                filesShowHiddenBinding: Binding(
                    get: { fileBrowser.showHiddenFiles(for: server.id) },
                    set: { fileBrowser.setShowHiddenFiles($0, serverId: server.id) }
                ),
                onFilesGoUp: {
                    Task { await fileBrowser.goUp(server: server) }
                },
                onFilesRefresh: {
                    Task { await fileBrowser.refresh(server: server) }
                },
                onExitZen: {
                    showingZenPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = false
                    }
                }
            )
        }
    }

    private func disconnectFromServer() {
        tabManager.closeAllTabs(for: server.id)
        fileBrowser.disconnect(serverId: server.id)
        tabManager.connectedServerIds.remove(server.id)
    }

    private func splitFocusedPane(_ direction: TerminalSplitDirection) {
        guard let selectedTab else { return }
        guard StoreManager.shared.isPro else {
            showingZenPanel = false
            showingSplitPaneUpgradeAlert = true
            return
        }

        switch direction {
        case .horizontal:
            _ = tabManager.splitHorizontal(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        case .vertical:
            _ = tabManager.splitVertical(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        }
    }
    #endif
}

#if os(macOS)
private struct HostingWindowObserver: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowChange = { [binding = _window] newWindow in
            binding.wrappedValue = newWindow
        }
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowChange = { [binding = _window] newWindow in
            binding.wrappedValue = newWindow
        }
        nsView.publishCurrentWindow()
    }
}

private final class WindowObserverView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        onWindowChange?(newWindow)
    }

    func publishCurrentWindow() {
        onWindowChange?(window)
    }
}
#endif

private extension View {
    @ViewBuilder
    func macOSZenExpandedTopSafeArea(_ isEnabled: Bool) -> some View {
        #if os(macOS)
        if isEnabled {
            self.ignoresSafeArea(.container, edges: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacOSZenWindowChromeBridge: NSViewRepresentable {
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
                    self?.triggerUpdate()
                }
            }
        }

        deinit {
            removeObservers()
        }
    }
}

private struct MacOSToolbarBackdrop: View {
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

private extension ConnectionTerminalContainer {
    var zenIndicatorColor: Color {
        guard let state = selectedTab.flatMap({ tabManager.paneStates[$0.focusedPaneId] }) else {
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

    var tabsStatusText: String {
        if serverTabs.isEmpty {
            return String(localized: "No terminals")
        }
        let count = serverTabs.count
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }

    var compactTabsStatusText: String {
        let count = serverTabs.count
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }

    var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    var disconnectActionTitle: String {
        String(localized: "Close")
    }

    var disconnectAlertMessage: String {
        serverTabs.isEmpty
            ? String(localized: "This will return to the server list.")
            : String(localized: "All terminal tabs for this server will be closed.")
    }
}
#endif

// MARK: - Terminal Tabs Scroll View

#if os(macOS)
struct TerminalTabsScrollView: View {
    let tabs: [TerminalTab]
    @Binding var selectedTabId: UUID?
    let onClose: (TerminalTab) -> Void
    let onNew: () -> Void
    @ObservedObject var tabManager: TerminalTabManager

    @State private var isNewTabHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Navigation arrows
            HStack(spacing: 4) {
                NavigationArrowButton(
                    icon: "chevron.left",
                    action: { selectPrevious() },
                    help: String(localized: "Previous tab")
                )
                .disabled(tabs.count <= 1)

                NavigationArrowButton(
                    icon: "chevron.right",
                    action: { selectNext() },
                    help: String(localized: "Next tab")
                )
                .disabled(tabs.count <= 1)
            }
            .padding(.leading, 8)

            // Tabs scroll view
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.id) { tab in
                        TerminalTabButton(
                            tab: tab,
                            isSelected: selectedTabId == tab.id,
                            onSelect: { selectedTabId = tab.id },
                            onClose: { onClose(tab) },
                            tabManager: tabManager
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: 600, maxHeight: 36)

            // New tab button
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    .background(
                        isNewTabHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .onHover { isNewTabHovering = $0 }
            .help(Text("New terminal tab"))
            .padding(.trailing, 8)
        }
    }

    private func selectPrevious() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabId = tabs[currentIndex - 1].id
    }

    private func selectNext() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < tabs.count - 1 else { return }
        selectedTabId = tabs[currentIndex + 1].id
    }
}

// MARK: - Terminal Tab Button

struct TerminalTabButton: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ObservedObject var tabManager: TerminalTabManager

    @State private var isHovering = false

    /// Get pane state for the focused pane
    private var paneState: TerminalPaneState? {
        tabManager.paneStates[tab.focusedPaneId]
    }

    private var statusColor: Color {
        guard let state = paneState else { return .secondary }
        switch state.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                // Close button (like Aizen's DetailCloseButton)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)

                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                // Title
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)

                // Pane count indicator (if splits)
                if tab.paneCount > 1 {
                    Text(verbatim: "⊞")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ?
                Color(nsColor: .separatorColor) :
                (isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
#endif
