//
//  TerminalTabManager.swift
//  VivyTerm
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
    @Published var tabsByServer: [UUID: [TerminalTab]] = [:]

    /// Currently selected tab ID per server
    @Published var selectedTabByServer: [UUID: UUID] = [:]

    /// Servers that are currently "connected" (have at least one tab open)
    @Published var connectedServerIds: Set<UUID> = []

    /// Selected view type per server (stats/terminal)
    @Published var selectedViewByServer: [UUID: String] = [:]

    // MARK: - Terminal Registry

    /// Terminal views keyed by pane ID
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]

    private struct SSHShellRegistration {
        let serverId: UUID
        let client: SSHClient
        let shellId: UUID
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    private init() {}

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

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        paneStates[tab.rootPaneId] = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: server.id
        )

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
        paneStates[newPaneId] = TerminalPaneState(
            paneId: newPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )

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
    func registerSSHClient(_ client: SSHClient, shellId: UUID, for paneId: UUID, serverId: UUID) {
        if let existing = sshShells[paneId] {
            Task.detached { [client = existing.client, shellId = existing.shellId] in
                await client.closeShell(shellId)
            }
            serverShellCounts[existing.serverId] = max((serverShellCounts[existing.serverId] ?? 1) - 1, 0)
        }

        sshShells[paneId] = SSHShellRegistration(serverId: serverId, client: client, shellId: shellId)
        serverShellCounts[serverId, default: 0] += 1
        sharedSSHClients[serverId] = client
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

    /// Clean up a pane (terminal + SSH)
    private func cleanupPane(_ paneId: UUID) {
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
    }
}
