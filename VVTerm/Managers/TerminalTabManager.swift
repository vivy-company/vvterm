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
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)
    /// Server IDs with an in-flight tab-open request to avoid queued duplicates.
    private var tabOpensInFlight: Set<UUID> = []

    /// Pane state keyed by pane ID
    @Published var paneStates: [UUID: TerminalPaneState] = [:]

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver = TmuxAttachResolver()

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
    func openTab(for server: Server) async throws -> TerminalTab {
        if tabOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        tabOpensInFlight.insert(server.id)
        defer { tabOpensInFlight.remove(server.id) }

        guard await AppLockManager.shared.ensureServerUnlocked(server) else {
            throw VVTermError.authenticationFailed
        }

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
        rootState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off
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
        // Resolve the latest tab from manager state since the passed value can be stale.
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("splitPane: tab not found \(tab.id.uuidString, privacy: .public)")
            return nil
        }

        let paneExists: Bool
        if let layout = currentTab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = currentTab.rootPaneId == paneId
        }
        guard paneExists else {
            logger.warning("splitPane: pane not found \(paneId.uuidString, privacy: .public)")
            return nil
        }

        let newPaneId = UUID()

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var newState = TerminalPaneState(
            paneId: newPaneId,
            tabId: currentTab.id,
            serverId: currentTab.serverId
        )
        newState.workingDirectory = paneStates[paneId]?.workingDirectory
        newState.seedPaneId = paneId
        newState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: currentTab.serverId) ? .unknown : .off
        paneStates[newPaneId] = newState

        // Create the new split node
        let newSplit = TerminalSplitNode.split(TerminalSplitNode.Split(
            direction: direction,
            ratio: 0.5,
            left: .leaf(paneId: paneId),
            right: .leaf(paneId: newPaneId)
        ))

        // Update tab layout
        var updatedTab = currentTab
        if let currentLayout = currentTab.layout {
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
        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration for pane \(paneId.uuidString, privacy: .public)")
            Task.detached(priority: .utility) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return
        }

        if let replaced = registerResult.replacedShell {
            Task.detached { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

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
        let unregisterResult = shellRegistry.unregister(for: paneId)

        guard let registration = unregisterResult.registration else {
            if let pendingStart = unregisterResult.pendingStart {
                if !shellRegistry.hasClientReferences(pendingStart.client) {
                    await pendingStart.client.disconnect()
                }
            }
            return
        }

        await registration.client.closeShell(registration.shellId)

        if !shellRegistry.hasClientReferences(registration.client) {
            await registration.client.disconnect()
        }

        paneStates[paneId]?.activeTransport = .ssh
        paneStates[paneId]?.moshFallbackReason = nil
    }

    /// Get SSH client for a pane
    func getSSHClient(for paneId: UUID) -> SSHClient? {
        shellRegistry.client(for: paneId)
    }

    func shellId(for paneId: UUID) -> UUID? {
        shellRegistry.shellId(for: paneId)
    }

    /// Returns true only for the first caller while no live shell exists for the pane.
    func tryBeginShellStart(for paneId: UUID, client: SSHClient) -> Bool {
        guard let serverId = paneStates[paneId]?.serverId else {
            return false
        }

        let startResult = shellRegistry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client
        )

        if let context = startResult.staleContext {
            logger.warning("Recovered stale pane shell-start lock for \(paneId.uuidString, privacy: .public)")
            if !shellRegistry.hasClientReferences(context.client) {
                Task.detached(priority: .utility) { [client = context.client] in
                    await client.disconnect()
                }
            }
        }
        return startResult.started
    }

    func finishShellStart(for paneId: UUID, client: SSHClient) {
        shellRegistry.finishStart(for: paneId, client: client)
    }

    func isShellStartInFlight(for paneId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: paneId)
        if let context = result.staleContext {
            logger.warning("Cleared stale pane shell-start in-flight flag for \(paneId.uuidString, privacy: .public)")
            if !shellRegistry.hasClientReferences(context.client) {
                Task.detached(priority: .utility) { [client = context.client] in
                    await client.disconnect()
                }
            }
        }
        return result.inFlight
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds {
                if let client = shellRegistry.client(for: paneId) {
                    return client
                }
            }
        }

        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                if let client = shellRegistry.client(for: paneId) {
                    return client
                }
            }
        }

        if let client = shellRegistry.firstRegisteredClient(for: serverId) {
            return client
        }

        if allowPendingStart, let client = shellRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    /// Returns the best-known client for this server, including pending shell starts.
    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    /// Returns only clients that already have a registered shell for this server.
    func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func hasOtherActivePanes(for serverId: UUID, excluding paneId: UUID) -> Bool {
        paneStates.contains { entry in
            entry.key != paneId && entry.value.serverId == serverId && entry.value.connectionState.isConnected
        }
    }

    /// Returns true when the same SSH client instance is registered to another live pane.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding paneId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: paneId)
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

        tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
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

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    func resolveTmuxAttachPrompt(paneId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(paneId: UUID) {
        tmuxResolver.cancelPrompt(entityId: paneId, setPrompt: setTmuxAttachPrompt)
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for tab in tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
                guard ownership == .managed else { continue }
                names.insert(tmuxResolver.sessionName(for: paneId))
            }
        }
        return names
    }

    private func currentTmuxStatus(for paneId: UUID, serverId: UUID) -> TmuxStatus {
        guard let tab = selectedTab(for: serverId) else { return .background }
        return (tab.id == selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
    }

    private func resolveTmuxWorkingDirectory(for paneId: UUID, using client: SSHClient) async -> String {
        if let seedPaneId = paneStates[paneId]?.seedPaneId,
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: seedPaneId),
               using: client
           ) {
            paneStates[paneId]?.workingDirectory = path
            return path
        }

        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxResolver.sessionName(for: paneId),
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
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.tmuxResolver.clearAttachmentState(for: paneId)
                self.updatePaneTmuxStatus(paneId, status: .off)
            }
            return
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            await MainActor.run {
                self.tmuxResolver.clearAttachmentState(for: paneId)
                self.updatePaneTmuxStatus(paneId, status: .missing)
            }
            return
        }

        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: managedTmuxSessionNames(for: serverId),
            using: client
        )
        tmuxCleanupServers = cleanupSet

        let status = await MainActor.run {
            self.currentTmuxStatus(for: paneId, serverId: serverId)
        }
        await MainActor.run {
            self.updatePaneTmuxStatus(paneId, status: status)
        }

        await RemoteTmuxManager.shared.prepareConfig(using: client)

        let command: String
        if let pending = tmuxResolver.pendingPostShellCommands.removeValue(forKey: paneId) {
            command = pending
        } else {
            let selection: TmuxAttachSelection
            if tmuxResolver.sessionOwnership[paneId] == .external {
                selection = .attachExisting(sessionName: tmuxResolver.sessionName(for: paneId))
            } else {
                selection = .createManaged
                tmuxResolver.sessionNames[paneId] = tmuxResolver.managedSessionName(for: paneId)
                tmuxResolver.sessionOwnership[paneId] = .managed
            }
            let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
            guard let rebuilt = tmuxResolver.buildAttachCommand(for: paneId, selection: selection, workingDirectory: workingDirectory) else {
                return
            }
            command = rebuilt
        }

        await RemoteTmuxManager.shared.sendScript(command, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        tmuxResolver.pendingPostShellCommands.removeValue(forKey: paneId)

        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            tmuxResolver.clearAttachmentState(for: paneId)
            updatePaneTmuxStatus(paneId, status: .off)
            return (nil, true)
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            tmuxResolver.clearAttachmentState(for: paneId)
            updatePaneTmuxStatus(paneId, status: .missing)
            return (nil, true)
        }

        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: managedTmuxSessionNames(for: serverId),
            using: client
        )
        tmuxCleanupServers = cleanupSet

        let selection = await tmuxResolver.resolveSelection(
            for: paneId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updatePaneTmuxStatus(paneId, status: .off)
            return (nil, true)
        }

        updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
        await RemoteTmuxManager.shared.prepareConfig(using: client)

        let connectionMode = ServerManager.shared.servers
            .first(where: { $0.id == serverId })?
            .connectionMode ?? .standard

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)

        switch selection {
        case .skipTmux:
            return (nil, true)
        case .createManaged:
            if connectionMode == .mosh {
                tmuxResolver.pendingPostShellCommands[paneId] = RemoteTmuxManager.shared.attachCommand(
                    sessionName: tmuxResolver.sessionName(for: paneId),
                    workingDirectory: workingDirectory
                )
                return (nil, false)
            }
            return (
                RemoteTmuxManager.shared.attachExecCommand(
                    sessionName: tmuxResolver.sessionName(for: paneId),
                    workingDirectory: workingDirectory
                ),
                true
            )
        case .attachExisting(let sessionName):
            if connectionMode == .mosh {
                tmuxResolver.pendingPostShellCommands[paneId] = RemoteTmuxManager.shared.attachExistingCommand(sessionName: sessionName)
                return (nil, false)
            }
            return (
                RemoteTmuxManager.shared.attachExistingExecCommand(sessionName: sessionName),
                true
            )
        }
    }

    func startTmuxInstall(for paneId: UUID) async {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: registration.client)
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: sessionName,
            workingDirectory: workingDirectory
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client)
                if available {
                    await MainActor.run {
                        self.tmuxResolver.sessionNames[paneId] = sessionName
                        self.tmuxResolver.sessionOwnership[paneId] = .managed
                        self.updatePaneTmuxStatus(paneId, status: self.currentTmuxStatus(for: paneId, serverId: serverId))
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
        guard let registration = shellRegistry.registration(for: paneId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    func killTmuxIfNeeded(for paneId: UUID) {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        Task.detached { [client = registration.client, sessionName] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
        }
    }

    func disableTmux(for serverId: UUID) {
        for (paneId, state) in paneStates where state.serverId == serverId {
            paneStates[paneId]?.tmuxStatus = .off
            tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
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
                        if !tmuxResolver.isTmuxEnabled(for: tab.serverId) {
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

#if DEBUG
extension TerminalTabManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil

        let allPaneIds = Set(paneStates.keys)
            .union(shellRegistry.startsInFlight.keys)
        for paneId in allPaneIds {
            tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
        }

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellRegistry.registrations.values {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for context in shellRegistry.startsInFlight.values {
            uniqueClients[ObjectIdentifier(context.client)] = context.client
        }

        let terminals = Array(terminalViews.values)
        isRestoring = true
        tabsByServer = [:]
        selectedTabByServer = [:]
        connectedServerIds = []
        selectedViewByServer = [:]
        paneStates = [:]
        tmuxAttachPrompt = nil
        terminalRegistryVersion = 0
        terminalViews.removeAll()
        shellRegistry.removeAll()
        tabOpensInFlight.removeAll()
        tmuxCleanupServers.removeAll()
        isRestoring = false

        UserDefaults.standard.removeObject(forKey: persistenceKey)
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }
}
#endif
