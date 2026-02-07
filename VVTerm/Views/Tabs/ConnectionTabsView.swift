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
    let server: Server

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme

    /// Cached terminal background color from theme
    @State private var terminalBackgroundColor: Color = .black

    /// Theme name from settings
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true

    /// Disconnect confirmation
    @State private var showingDisconnectConfirmation = false

    /// Tab limit alert
    @State private var showingTabLimitAlert = false

    /// Selected view type - persisted per server
    private var selectedView: String {
        tabManager.selectedViewByServer[server.id] ?? "stats"
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var selectedViewBinding: Binding<String> {
        Binding(
            get: { tabManager.selectedViewByServer[server.id] ?? "stats" },
            set: { newValue in
                let current = tabManager.selectedViewByServer[server.id] ?? "stats"
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedViewByServer[server.id] = newValue
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

    var body: some View {
        ZStack {
            // Stats view - always in hierarchy, visibility controlled by opacity
            // Pass isVisible to pause/resume collection when hidden
            ServerStatsView(
                server: server,
                isVisible: selectedView == "stats",
                sharedClientProvider: { tabManager.sharedStatsClient(for: server.id) }
            )
                .opacity(selectedView == "stats" ? 1 : 0)
                .allowsHitTesting(selectedView == "stats")
                .zIndex(selectedView == "stats" ? 1 : 0)

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
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .zIndex(isVisible ? 1 : 0)
            }

            // Empty state when in terminal view with no tabs
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
            }
            #else
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selectedView == "terminal" ? terminalBackgroundColor : nil)
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
        }
        #if os(macOS)
        .focusedValue(\.openTerminalTab, handleNewTabCommand)
        .toolbar {
            viewPickerToolbarItem
            if selectedView == "terminal" && !serverTabs.isEmpty {
                tabsToolbarItem
            }
            toolbarSpacer
            disconnectToolbarItem
        }
        #endif
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
    }

    private func handleNewTabCommand() {
        tabManager.selectedViewByServer[server.id] = "terminal"
        openNewTab()
    }

    private func openNewTab() {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }
        let tab = tabManager.openTab(for: server)
        selectedTabIdBinding.wrappedValue = tab.id
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)
            await MainActor.run {
                if let color = resolved {
                    terminalBackgroundColor = color
                    UserDefaults.standard.set(color.toHex(), forKey: "terminalBackgroundColor")
                } else {
                    #if os(macOS)
                    terminalBackgroundColor = Color(NSColor.windowBackgroundColor)
                    #elseif os(iOS)
                    terminalBackgroundColor = Color(UIColor.systemBackground)
                    #else
                    terminalBackgroundColor = .black
                    #endif
                }
            }
        }
    }

    // MARK: - Toolbar Items (macOS)

    #if os(macOS)
    @ToolbarContentBuilder
    private var viewPickerToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("View", selection: selectedViewBinding) {
                Label("Stats", systemImage: "chart.bar.xaxis")
                    .tag("stats")
                Label("Terminal", systemImage: "terminal")
                    .tag("terminal")
            }
            .pickerStyle(.segmented)
        }
    }

    @ToolbarContentBuilder
    private var tabsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
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
    private var disconnectToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(serverTabs.isEmpty ? Color.secondary : Color.green)
                    .frame(width: 8, height: 8)
                Text(tabsStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingDisconnectConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.red)
            }
            .help(Text("Disconnect from server"))
            .confirmationDialog(
                String(format: String(localized: "Disconnect from %@?"), server.name),
                isPresented: $showingDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    disconnectFromServer()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(disconnectMessage)
            }
        }
    }

    private func disconnectFromServer() {
        tabManager.closeAllTabs(for: server.id)
        tabManager.connectedServerIds.remove(server.id)
    }
    #endif
}

#if os(macOS)
private extension ConnectionTerminalContainer {
    var tabsStatusText: String {
        if serverTabs.isEmpty {
            return String(localized: "No terminals")
        }
        let count = serverTabs.count
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }

    var disconnectMessage: String {
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
