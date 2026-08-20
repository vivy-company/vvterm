#if os(iOS)
import SwiftUI

private struct TerminalKeyboardSafeAreaHost<Content: View>: View {
    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey)
    private var preservesTerminalSizeForKeyboard = false

    let isTerminalSelected: Bool
    let content: Content

    init(
        isTerminalSelected: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.isTerminalSelected = isTerminalSelected
        self.content = content()
    }

    var body: some View {
        content.modifier(
            TerminalKeyboardSafeAreaModifier(
                isEnabled: preservesTerminalSizeForKeyboard && isTerminalSelected
            )
        )
    }
}

extension ConnectionTerminalContainer {
    var platformBody: some View {
        sharedBody
            .alert(
                disconnectAlertTitle,
                isPresented: $showingDisconnectConfirmation,
            ) {
                Button("Cancel", role: .cancel) {}
                Button(disconnectActionTitle, role: .destructive) {
                    disconnectFromServer()
                }
            } message: {
                Text(disconnectAlertMessage)
            }
            .terminalCloseConfirmationAlert(
                isPresented: $showingPaneCloseConfirmation,
                message: String(localized: "The SSH connection will be terminated."),
                onClose: closeFocusedPaneConfirmed
            )
            .sheet(item: $serverToEdit) { editingServer in
                NavigationStack {
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
                }
                .adaptiveSoftScrollEdges()
            }
    }

    func platformChrome(backgroundColor: Color) -> some View {
        TerminalKeyboardSafeAreaHost(isTerminalSelected: selectedView == .terminal) {
            VStack(spacing: 0) {
                if !isZenModeEnabled {
                    headerTabsBar
                }

                platformContentStack(backgroundColor: backgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(backgroundColor)
            }
            .overlay(alignment: .topTrailing) {
                if isZenModeEnabled {
                    zenModeOverlay
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .background(backgroundColor.ignoresSafeArea(.all))
        }
    }

    @ViewBuilder
    private func platformContentStack(backgroundColor: Color) -> some View {
        Group {
            switch selectedView {
            case .stats:
                statsLayer(backgroundColor: backgroundColor)
            case .files:
                filesLayer
            case .terminal:
                terminalLayer
            }
        }
        // View switches must swap content without implicit animations: animating
        // the insertion of the Metal-backed terminal view during the segmented
        // picker's transition hangs the main thread in a trait-update loop.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private func statsLayer(backgroundColor: Color) -> some View {
        // Mount stats only while selected. The dashboard nests ViewThatFits,
        // Grid, and lazy stacks; keeping it in the hierarchy at opacity 0 makes
        // every layout pass of the other views re-measure it, which explodes
        // combinatorially and hangs the main thread when the terminal mounts.
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
    var terminalLayer: some View {
        if selectedView == .terminal, let tab = selectedTab {
            let voiceRuntime = voiceInputRuntimeStore.runtime(for: tab.id)
            TerminalTabView(
                tab: tab,
                server: server,
                tabManager: tabManager,
                securityActions: terminalSecurityActions,
                isSelected: true,
                isSplitZoomed: terminalContent.state.splitZoomedTabIds.contains(tab.id),
                appearance: terminalAppearanceSnapshot,
                voiceSettingsStore: voiceInputRuntimeStore.settingsStore,
                audioService: voiceRuntime.audioService,
                voiceRecordingOperation: voiceRuntime.recordingOperation
            )
            // Per-tab identity: without it SwiftUI reuses the previous tab's
            // representable (and its Ghostty view + SSH coordinator) when the
            // selected tab changes.
            .id(tab.id)
        }

        if selectedView == .terminal && serverTabs.isEmpty {
            TerminalEmptyStateView(server: server) {
                openNewTab()
            }
        }
    }

    @ViewBuilder
    private var headerTabsBar: some View {
        if selectedView == .terminal && serverTabs.count > 1 {
            SharedTerminalTabsBar(
                tabs: serverTabs,
                selectedTabId: selectedTabIdBinding,
                projection: terminalToolbarProjection.tabStrip,
                onClose: { tabManager.closeTab($0) }
            )
        }

        if selectedView == .files && serverFileTabs.count > 1 {
            RemoteFileTabsBar(
                tabs: serverFileTabs,
                selectedTabId: selectedFileTabIdBinding,
                titleForTab: displayedFileTabTitle(for:),
                onSelect: { fileTabManager.selectTab($0) },
                onClose: { tab in
                    if let removedTab = fileTabManager.closeTab(tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                }
            )
        }
    }

    private func disconnectFromServer() {
        statsDependencies.runtimeStore.releaseCollector(for: server.id)
        tabManager.disconnectServer(server.id)
        fileBrowser.disconnect(serverId: server.id)
        fileTabManager.disconnect(serverId: server.id)
    }

    func platformHandleSelectedViewChange(_ selectedView: ConnectionViewTabID) {
        guard selectedView != .terminal else { return }
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                tabManager.presentationState.applyVoiceEvent(.pendingReturnDismissed, for: paneId)
            }
        }
    }

    func platformPrepareForPaneClose() {
        tabManager.keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
    }

    private var zenModeOverlay: some View {
        ZenModeFloatingOverlay(isPanelPresented: $showingZenPanel) { panelWidth in
            IOSZenModePanel(
                width: panelWidth,
                serverName: server.name,
                selectedView: selectedView,
                selectedViewBinding: selectedViewBinding,
                viewTabs: visibleViewTabs,
                terminalTabs: serverTabs,
                selectedTerminalTabId: selectedTabIdBinding,
                terminalTabTitle: { tabManager.titleStore.displayTitle(for: $0) },
                paneState: { tabManager.sessionState.paneState(for: $0.focusedPaneId) },
                onCloseTerminalTab: { tabManager.closeTab($0) },
                fileTabs: serverFileTabs,
                selectedFileTabId: selectedFileTabIdBinding,
                fileTabTitle: displayedFileTabTitle(for:),
                onSelectFileTab: { fileTabManager.selectTab($0) },
                onCloseFileTab: { tab in
                    if let removedTab = fileTabManager.closeTab(tab) {
                        fileBrowser.removeState(for: removedTab.id)
                    }
                },
                onNewTerminalTab: {
                    showingZenPanel = false
                    openNewTab(selectTerminalViewOnSuccess: true)
                },
                onNewFileTab: {
                    showingZenPanel = false
                    openNewFileTab(selectFilesViewOnSuccess: true)
                },
                onOpenSettings: {
                    showingZenPanel = false
                    onOpenSettings?()
                },
                onEditServer: {
                    showingZenPanel = false
                    serverToEdit = server
                },
                onDisconnect: {
                    showingZenPanel = false
                    statsDependencies.runtimeStore.releaseCollector(for: server.id)
                    if let onDisconnectRoute {
                        onDisconnectRoute()
                    } else {
                        disconnectFromServer()
                    }
                },
                onBack: {
                    showingZenPanel = false
                    onLeaveRoute?()
                },
                onExitZen: exitZenMode
            )
        }
    }

    private func exitZenMode() {
        showingZenPanel = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isZenModeEnabled = false
        }
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
}

private struct SharedTerminalTabsBar: View {
    let tabs: [TerminalTab]
    @Binding var selectedTabId: UUID?
    @ObservedObject var projection: TerminalServerToolbarTabStripProjection
    let onClose: (TerminalTab) -> Void

    private let minTabWidth: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let count = max(tabs.count, 1)
            let availableWidth = max(proxy.size.width - ServerViewTopTabBarMetrics.horizontalPadding * 2, 0)
            let totalSpacing = ServerViewTopTabBarMetrics.tabSpacing * CGFloat(max(count - 1, 0))
            let itemWidth = count > 0 ? (availableWidth - totalSpacing) / CGFloat(count) : 0
            let useEqualWidth = itemWidth >= minTabWidth

            Group {
                if useEqualWidth {
                    HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                        ForEach(tabs) { tab in
                            let item = tabItem(for: tab)
                            SharedTerminalTabButton(
                                title: item?.title ?? tab.title,
                                statusColor: statusColor(for: item),
                                isSelected: selectedTabId == tab.id,
                                fixedWidth: itemWidth,
                                onSelect: { selectedTabId = tab.id },
                                onClose: { onClose(tab) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                    .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ServerViewTopTabBarMetrics.tabSpacing) {
                            ForEach(tabs) { tab in
                                let item = tabItem(for: tab)
                                SharedTerminalTabButton(
                                    title: item?.title ?? tab.title,
                                    statusColor: statusColor(for: item),
                                    isSelected: selectedTabId == tab.id,
                                    fixedWidth: nil,
                                    onSelect: { selectedTabId = tab.id },
                                    onClose: { onClose(tab) }
                                )
                                .frame(minWidth: minTabWidth)
                            }
                        }
                        .padding(.horizontal, ServerViewTopTabBarMetrics.horizontalPadding)
                        .padding(.vertical, ServerViewTopTabBarMetrics.barVerticalInset)
                        .animation(nil, value: tabs.map(\.id))
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(height: ServerViewTopTabBarMetrics.barHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(Capsule(style: .continuous))
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    private func tabItem(for tab: TerminalTab) -> TerminalServerToolbarTabItem? {
        projection.state.items.first { $0.id == tab.id }
    }

    private func statusColor(for item: TerminalServerToolbarTabItem?) -> Color {
        switch item?.connectionState ?? .idle {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .failed:
            return .red
        case .disconnected, .idle:
            return .secondary
        }
    }
}

private struct SharedTerminalTabButton: View {
    let title: String
    let statusColor: Color
    let isSelected: Bool
    let fixedWidth: CGFloat?
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 36)
        .padding(.vertical, ServerViewTopTabBarMetrics.tabVerticalPadding)
        .frame(height: ServerViewTopTabBarMetrics.tabHeight)
        .frame(width: fixedWidth, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            isSelected ? Color.primary.opacity(0.18) : Color.clear,
            in: Capsule(style: .continuous)
        )
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isSelected ? 0.16 : 0.12))
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
#endif
