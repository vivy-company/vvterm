//
//  TerminalTabManager.swift
//  VVTerm
//
//  Manages terminal tabs and their panes.
//  - Tabs are shown in the toolbar
//  - Each tab can have multiple panes via splits
//  - Panes are NOT tabs - they're split views within a tab
//

import Foundation
import SwiftUI
import Combine
import os.log

#if os(macOS)
import AppKit
#endif

@MainActor
final class TerminalTabManager: ObservableObject {
    static let shared = TerminalTabManager()

    // MARK: - Published State

    /// All tabs, organized by server
    @Published var tabsByServer: [UUID: [TerminalTab]] = [:] {
        didSet { schedulePersist() }
    }

    /// Currently selected tab ID per server
    @Published var selectedTabByServer: [UUID: UUID] = [:] {
        didSet {
            schedulePersist()
            updateTmuxSelectionStatuses()
        }
    }

    /// Servers that are currently "connected" (have at least one tab open)
    @Published var connectedServerIds: Set<UUID> = []

    /// Selected view type per server (stats/terminal)
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    // MARK: - Terminal Registry

    /// Terminal views keyed by pane ID
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]

    private struct SSHShellRegistration {
        let serverId: UUID
        let client: SSHClient
        let shellId: UUID
        let transport: ShellTransport
        let fallbackReason: MoshFallbackReason?
    }

    /// Shell handles keyed by pane ID
    private var sshShells: [UUID: SSHShellRegistration] = [:]

    /// Shared SSH clients per server
    private var sharedSSHClients: [UUID: SSHClient] = [:]

    /// Shell counts per server for shared client lifecycle
    private var serverShellCounts: [UUID: Int] = [:]

    /// Pane state keyed by pane ID
    @Published var paneStates: [UUID: TerminalPaneState] = [:]

    /// Bumps when a terminal view is registered/unregistered so views refresh.
    @Published private(set) var terminalRegistryVersion: Int = 0

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    private let persistenceKey = "terminalTabsSnapshot.v1"
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    // MARK: - Tab Management

    /// Get tabs for a server
    func tabs(for serverId: UUID) -> [TerminalTab] {
        tabsByServer[serverId] ?? []
    }

    /// Get currently selected tab for a server
    func selectedTab(for serverId: UUID) -> TerminalTab? {
        guard let tabId = selectedTabByServer[serverId] else {
            return tabs(for: serverId).first
        }
        return tabs(for: serverId).first { $0.id == tabId }
    }

    /// Check if can open new tab (Pro limit check)
    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        let totalTabs = tabsByServer.values.flatMap { $0 }.count
        return totalTabs < FreeTierLimits.maxTabs
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) -> TerminalTab {
        let tab = TerminalTab(serverId: server.id, title: server.name)

        let sourcePaneId = selectedTab(for: server.id)?.focusedPaneId
        let sourceWorkingDirectory = sourcePaneId
            .flatMap { paneStates[$0]?.workingDirectory }

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var rootState = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: server.id
        )
        rootState.workingDirectory = sourceWorkingDirectory
        rootState.seedPaneId = sourcePaneId
        rootState.tmuxStatus = isTmuxEnabled(for: server.id) ? .unknown : .off
        paneStates[tab.rootPaneId] = rootState

        // Now update tabs (triggers @Published, view will have state ready)
        var serverTabs = tabsByServer[server.id] ?? []
        serverTabs.append(tab)
        tabsByServer[server.id] = serverTabs

        // Select the new tab
        selectedTabByServer[server.id] = tab.id

        // Mark server as connected
        connectedServerIds.insert(server.id)

        logger.info("Opened new tab for \(server.name), pane: \(tab.rootPaneId)")
        return tab
    }

    /// Close a tab
    func closeTab(_ tab: TerminalTab) {
        // Clean up all panes in this tab
        for paneId in tab.allPaneIds {
            cleanupPane(paneId)
        }

        // Remove from tabs
        if var serverTabs = tabsByServer[tab.serverId] {
            serverTabs.removeAll { $0.id == tab.id }
            tabsByServer[tab.serverId] = serverTabs

            // Select another tab if this was selected
            if selectedTabByServer[tab.serverId] == tab.id {
                selectedTabByServer[tab.serverId] = serverTabs.first?.id
            }

            // Note: Don't remove from connectedServerIds here
            // User might still be viewing stats. Explicit disconnect handles that.
        }

        logger.info("Closed tab \(tab.id)")
    }

    /// Close all tabs for a server
    func closeAllTabs(for serverId: UUID) {
        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            closeTab(tab)
        }
    }

    // MARK: - Split Management

    /// Split a pane horizontally (left | right)
    func splitHorizontal(tab: TerminalTab, paneId: UUID) -> UUID? {
        guard StoreManager.shared.isPro else { return nil }
        return splitPane(tab: tab, paneId: paneId, direction: .horizontal)
    }

    /// Split a pane vertically (top / bottom)
    func splitVertical(tab: TerminalTab, paneId: UUID) -> UUID? {
        guard StoreManager.shared.isPro else { return nil }
        return splitPane(tab: tab, paneId: paneId, direction: .vertical)
    }

    private func splitPane(tab: TerminalTab, paneId: UUID, direction: TerminalSplitDirection) -> UUID? {
        let newPaneId = UUID()

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var newState = TerminalPaneState(
            paneId: newPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
        newState.workingDirectory = paneStates[paneId]?.workingDirectory
        newState.seedPaneId = paneId
        newState.tmuxStatus = isTmuxEnabled(for: tab.serverId) ? .unknown : .off
        paneStates[newPaneId] = newState

        // Create the new split node
        let newSplit = TerminalSplitNode.split(TerminalSplitNode.Split(
            direction: direction,
            ratio: 0.5,
            left: .leaf(paneId: paneId),
            right: .leaf(paneId: newPaneId)
        ))

        // Update tab layout
        var updatedTab = tab
        if let currentLayout = tab.layout {
            updatedTab.layout = currentLayout.replacingPane(paneId, with: newSplit).equalized()
        } else {
            // No layout yet - create one with the split
            updatedTab.layout = newSplit
        }
        updatedTab.focusedPaneId = newPaneId

        // Update tabs array (triggers @Published, view will have state ready)
        updateTab(updatedTab)

        logger.info("Split pane \(paneId) \(direction.rawValue), new pane: \(newPaneId)")
        return newPaneId
    }

    /// Close a pane within a tab
    func closePane(tab: TerminalTab, paneId: UUID) {
        // Get current tab from manager (passed tab might be stale)
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closePane: tab not found")
            return
        }

        let paneExists: Bool
        if let layout = currentTab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = currentTab.rootPaneId == paneId
        }
        guard paneExists else {
            logger.warning("closePane: pane not found \(paneId)")
            return
        }

        // If this is the only pane, close the tab
        if currentTab.paneCount <= 1 {
            closeTab(currentTab)
            return
        }

        // Update layout FIRST (before cleanup) to avoid "Initializing" flash
        // When cleanupPane triggers @Published, the pane won't be rendered anymore
        var updatedTab = currentTab
        if let currentLayout = currentTab.layout,
           let newLayout = currentLayout.removingPane(paneId) {
            // Always keep the layout - even for single pane
            // This ensures allPaneIds returns the correct remaining pane
            // (not rootPaneId which might have been closed)
            updatedTab.layout = newLayout.equalized()

            // Update focus if needed
            if updatedTab.focusedPaneId == paneId {
                updatedTab.focusedPaneId = newLayout.allPaneIds().first ?? currentTab.rootPaneId
            }
        }
        updateTab(updatedTab)

        // Now clean up the pane (after layout is updated)
        cleanupPane(paneId)
        logger.info("Closed pane \(paneId)")
    }

    /// Update a tab in the tabs array
    func updateTab(_ tab: TerminalTab) {
        guard var serverTabs = tabsByServer[tab.serverId],
              let index = serverTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        serverTabs[index] = tab
        tabsByServer[tab.serverId] = serverTabs
        updateTmuxFocus(for: tab)
    }

    // MARK: - Terminal Registry

    /// Register a terminal view for a pane
    func registerTerminal(_ terminal: GhosttyTerminalView, for paneId: UUID) {
        terminalViews[paneId] = terminal
        terminalRegistryVersion &+= 1
    }

    /// Unregister a terminal view
    func unregisterTerminal(for paneId: UUID) {
        if let terminal = terminalViews.removeValue(forKey: paneId) {
            terminal.cleanup()
        }
        terminalRegistryVersion &+= 1
    }

    /// Get terminal for a pane
    func getTerminal(for paneId: UUID) -> GhosttyTerminalView? {
        terminalViews[paneId]
    }

    /// Register SSH client for a pane
    func sharedSSHClient(for server: Server) -> SSHClient {
        if let client = sharedSSHClients[server.id] {
            return client
        }
        let client = SSHClient()
        sharedSSHClients[server.id] = client
        return client
    }

    /// Register SSH shell for a pane
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) {
        if let existing = sshShells[paneId] {
            Task.detached { [client = existing.client, shellId = existing.shellId] in
                await client.closeShell(shellId)
            }
            serverShellCounts[existing.serverId] = max((serverShellCounts[existing.serverId] ?? 1) - 1, 0)
        }

        sshShells[paneId] = SSHShellRegistration(
            serverId: serverId,
            client: client,
            shellId: shellId,
            transport: transport,
            fallbackReason: fallbackReason
        )
        serverShellCounts[serverId, default: 0] += 1
        sharedSSHClients[serverId] = client

        paneStates[paneId]?.activeTransport = transport
        paneStates[paneId]?.moshFallbackReason = fallbackReason

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(paneId: paneId, serverId: serverId, client: client, shellId: shellId)
            }
        }
    }

    /// Unregister SSH shell
    func unregisterSSHClient(for paneId: UUID) async {
        guard let registration = sshShells.removeValue(forKey: paneId) else { return }

        await registration.client.closeShell(registration.shellId)

        let serverId = registration.serverId
        let newCount = max((serverShellCounts[serverId] ?? 1) - 1, 0)
        serverShellCounts[serverId] = newCount

        if newCount == 0, let client = sharedSSHClients.removeValue(forKey: serverId) {
            await client.disconnect()
        }

        paneStates[paneId]?.activeTransport = .ssh
        paneStates[paneId]?.moshFallbackReason = nil
    }

    /// Get SSH client for a pane
    func getSSHClient(for paneId: UUID) -> SSHClient? {
        sshShells[paneId]?.client
    }

    func shellId(for paneId: UUID) -> UUID? {
        sshShells[paneId]?.shellId
    }

    func sshClient(for serverId: UUID) -> SSHClient? {
        if let client = sharedSSHClients[serverId] {
            return client
        }

        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds {
                if let client = sshShells[paneId]?.client {
                    return client
                }
            }
        }

        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                if let client = sshShells[paneId]?.client {
                    return client
                }
            }
        }

        return nil
    }

    func activeTransport(for paneId: UUID) -> ShellTransport {
        paneStates[paneId]?.activeTransport ?? .ssh
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if selectedTransport(for: serverId) == .mosh {
            return nil
        }
        return sshClient(for: serverId)
    }

    private func selectedTransport(for serverId: UUID) -> ShellTransport {
        if let selectedTab = selectedTab(for: serverId),
           let state = paneStates[selectedTab.focusedPaneId] {
            return state.activeTransport
        }

        if let connectedPane = paneStates.values.first(where: { $0.serverId == serverId && $0.connectionState.isConnected }) {
            return connectedPane.activeTransport
        }

        return paneStates.values.first(where: { $0.serverId == serverId })?.activeTransport ?? .ssh
    }

    /// Clean up a pane (terminal + SSH)
    private func cleanupPane(_ paneId: UUID) {
        if let status = paneStates[paneId]?.tmuxStatus,
           status == .foreground || status == .background || status == .installing {
            killTmuxIfNeeded(for: paneId)
        }

        unregisterTerminal(for: paneId)
        paneStates.removeValue(forKey: paneId)

        Task.detached { [weak self] in
            await self?.unregisterSSHClient(for: paneId)
        }
    }

    // MARK: - Pane State

    /// Update connection state for a pane
    func updatePaneState(_ paneId: UUID, connectionState: ConnectionState) {
        paneStates[paneId]?.connectionState = connectionState
        switch connectionState {
        case .connecting, .reconnecting:
            paneStates[paneId]?.activeTransport = .ssh
            paneStates[paneId]?.moshFallbackReason = nil
        case .disconnected, .failed:
            if paneStates[paneId]?.tmuxStatus == .foreground {
                paneStates[paneId]?.tmuxStatus = .background
            }
        case .connected, .idle:
            break
        }
    }

    func updatePaneWorkingDirectory(_ paneId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        paneStates[paneId]?.workingDirectory = normalized
    }

    func workingDirectory(for paneId: UUID) -> String? {
        paneStates[paneId]?.workingDirectory
    }

    func shouldApplyWorkingDirectory(for paneId: UUID) -> Bool {
        guard let status = paneStates[paneId]?.tmuxStatus else { return false }
        return status == .off || status == .missing
    }

    func updatePaneTmuxStatus(_ paneId: UUID, status: TmuxStatus) {
        paneStates[paneId]?.tmuxStatus = status
    }

    // MARK: - tmux Integration

    private var tmuxEnabledDefault: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "terminalTmuxEnabledDefault") == nil {
            return true
        }
        return defaults.bool(forKey: "terminalTmuxEnabledDefault")
    }

    private func isTmuxEnabled(for serverId: UUID) -> Bool {
        if let server = ServerManager.shared.servers.first(where: { $0.id == serverId }) {
            if let override = server.tmuxEnabledOverride {
                return override
            }
        }
        return tmuxEnabledDefault
    }

    private func tmuxSessionName(for paneId: UUID) -> String {
        "vvterm_\(DeviceIdentity.id)_\(paneId.uuidString)"
    }

    private func resolveTmuxWorkingDirectory(for paneId: UUID, using client: SSHClient) async -> String {
        if let seedPaneId = paneStates[paneId]?.seedPaneId,
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxSessionName(for: seedPaneId),
               using: client
           ) {
            paneStates[paneId]?.workingDirectory = path
            return path
        }

        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxSessionName(for: paneId),
            using: client
        ) {
            paneStates[paneId]?.workingDirectory = path
            return path
        }

        if let candidate = paneStates[paneId]?.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    private func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            return path.removingPercentEncoding ?? path
        }

        return trimmed
    }

    private func updateTmuxSelectionStatuses() {
        for serverId in tabsByServer.keys {
            let tabsForServer = tabs(for: serverId)
            for tab in tabsForServer {
                updateTmuxFocus(for: tab)
            }
        }
    }

    private func updateTmuxFocus(for tab: TerminalTab) {
        let isSelectedTab = selectedTabByServer[tab.serverId] == tab.id
        for paneId in tab.allPaneIds {
            guard let state = paneStates[paneId] else { continue }
            guard state.tmuxStatus == .foreground || state.tmuxStatus == .background else { continue }
            let newStatus: TmuxStatus = (isSelectedTab && tab.focusedPaneId == paneId) ? .foreground : .background
            if state.tmuxStatus != newStatus {
                paneStates[paneId]?.tmuxStatus = newStatus
            }
        }
    }

    private func handleTmuxLifecycle(
        paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.updatePaneTmuxStatus(paneId, status: .off)
            }
            return
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            await MainActor.run {
                self.updatePaneTmuxStatus(paneId, status: .missing)
            }
            return
        }

        if !tmuxCleanupServers.contains(serverId) {
            tmuxCleanupServers.insert(serverId)
            let keepNames = Set(tabs(for: serverId).flatMap { tab in
                tab.allPaneIds.map { tmuxSessionName(for: $0) }
            })
            await RemoteTmuxManager.shared.cleanupLegacySessions(using: client)
            await RemoteTmuxManager.shared.cleanupDetachedSessions(
                deviceId: DeviceIdentity.id,
                keeping: keepNames,
                using: client
            )
        }

        let status = await MainActor.run { () -> TmuxStatus in
            guard let tab = self.selectedTab(for: serverId) else { return .background }
            return (tab.id == self.selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
        }
        await MainActor.run {
            self.updatePaneTmuxStatus(paneId, status: status)
        }

        await RemoteTmuxManager.shared.prepareConfig(using: client)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        let command = RemoteTmuxManager.shared.attachCommand(
            sessionName: tmuxSessionName(for: paneId),
            workingDirectory: workingDirectory
        )
        await RemoteTmuxManager.shared.sendScript(command, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        guard isTmuxEnabled(for: serverId) else {
            updatePaneTmuxStatus(paneId, status: .off)
            return (nil, true)
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            updatePaneTmuxStatus(paneId, status: .missing)
            return (nil, true)
        }

        if !tmuxCleanupServers.contains(serverId) {
            tmuxCleanupServers.insert(serverId)
            let keepNames = Set(tabs(for: serverId).flatMap { tab in
                tab.allPaneIds.map { tmuxSessionName(for: $0) }
            })
            await RemoteTmuxManager.shared.cleanupLegacySessions(using: client)
            await RemoteTmuxManager.shared.cleanupDetachedSessions(
                deviceId: DeviceIdentity.id,
                keeping: keepNames,
                using: client
            )
        }

        let status = { () -> TmuxStatus in
            guard let tab = self.selectedTab(for: serverId) else { return .background }
            return (tab.id == self.selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
        }()
        updatePaneTmuxStatus(paneId, status: status)

        await RemoteTmuxManager.shared.prepareConfig(using: client)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        let command = RemoteTmuxManager.shared.attachExecCommand(
            sessionName: tmuxSessionName(for: paneId),
            workingDirectory: workingDirectory
        )
        return (command, true)
    }

    func startTmuxInstall(for paneId: UUID) async {
        guard let registration = sshShells[paneId] else { return }
        let serverId = registration.serverId
        guard isTmuxEnabled(for: serverId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: registration.client)
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: tmuxSessionName(for: paneId),
            workingDirectory: workingDirectory
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client)
                if available {
                    let status = await MainActor.run { () -> TmuxStatus in
                        guard let tab = self.selectedTab(for: serverId) else { return .background }
                        return (tab.id == self.selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
                    }
                    await MainActor.run {
                        self.updatePaneTmuxStatus(paneId, status: status)
                    }
                    return
                }
            }
            await MainActor.run {
                self.updatePaneTmuxStatus(paneId, status: .missing)
            }
        }
    }

    func installMoshServer(for paneId: UUID) async throws {
        guard let registration = sshShells[paneId] else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    func killTmuxIfNeeded(for paneId: UUID) {
        guard let registration = sshShells[paneId] else { return }
        let sessionName = tmuxSessionName(for: paneId)
        Task.detached { [client = registration.client, sessionName] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
        }
    }

    func disableTmux(for serverId: UUID) {
        for (paneId, state) in paneStates where state.serverId == serverId {
            paneStates[paneId]?.tmuxStatus = .off
        }
    }

    // MARK: - Persistence

    private func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self?.persistSnapshot()
            }
        }
    }

    private func persistSnapshot() {
        let serverSnapshots = tabsByServer.map { serverId, tabs in
            TerminalTabsSnapshot.ServerSnapshot(
                serverId: serverId,
                tabs: tabs.map { TerminalTabsSnapshot.TabSnapshot(from: $0) },
                selectedTabId: selectedTabByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }

        let snapshot = TerminalTabsSnapshot(servers: serverSnapshots)
        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to persist tabs snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(TerminalTabsSnapshot.self, from: data)
            isRestoring = true

            var restoredTabsByServer: [UUID: [TerminalTab]] = [:]
            var restoredSelectedTabs: [UUID: UUID] = [:]
            var restoredSelectedViews: [UUID: String] = [:]
            var restoredPaneStates: [UUID: TerminalPaneState] = [:]

            for server in snapshot.servers {
                let tabs = server.tabs.map { $0.toTerminalTab() }
                restoredTabsByServer[server.serverId] = tabs
                if let selected = server.selectedTabId {
                    restoredSelectedTabs[server.serverId] = selected
                }
                if let view = server.selectedView {
                    restoredSelectedViews[server.serverId] = view
                }

                for tab in tabs {
                    for paneId in tab.allPaneIds {
                        var paneState = TerminalPaneState(
                            paneId: paneId,
                            tabId: tab.id,
                            serverId: tab.serverId
                        )
                        if !isTmuxEnabled(for: tab.serverId) {
                            paneState.tmuxStatus = .off
                        }
                        restoredPaneStates[paneId] = paneState
                    }
                }
            }

            tabsByServer = restoredTabsByServer
            selectedTabByServer = restoredSelectedTabs
            selectedViewByServer = restoredSelectedViews
            paneStates = restoredPaneStates
            connectedServerIds = Set(restoredTabsByServer.keys)
        } catch {
            logger.error("Failed to restore tabs snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}

// MARK: - Persistence Snapshot

private struct TerminalTabsSnapshot: Codable {
    struct ServerSnapshot: Codable {
        let serverId: UUID
        let tabs: [TabSnapshot]
        let selectedTabId: UUID?
        let selectedView: String?
    }

    struct TabSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let layout: TerminalSplitNode?
        let focusedPaneId: UUID
        let rootPaneId: UUID

        init(from tab: TerminalTab) {
            self.id = tab.id
            self.serverId = tab.serverId
            self.title = tab.title
            self.createdAt = tab.createdAt
            self.layout = tab.layout
            self.focusedPaneId = tab.focusedPaneId
            self.rootPaneId = tab.rootPaneId
        }

        func toTerminalTab() -> TerminalTab {
            TerminalTab(
                id: id,
                serverId: serverId,
                title: title,
                createdAt: createdAt,
                rootPaneId: rootPaneId,
                focusedPaneId: focusedPaneId,
                layout: layout
            )
        }
    }

    let servers: [ServerSnapshot]
}
