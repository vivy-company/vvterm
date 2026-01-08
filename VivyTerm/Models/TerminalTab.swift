//
//  TerminalTab.swift
//  VivyTerm
//
//  A tab containing one or more terminal panes (via splits).
//  Each tab is independent - splits happen within a tab, not across tabs.
//

import Foundation

// MARK: - Terminal Tab

/// Represents a single tab in the terminal toolbar.
/// Each tab can contain multiple panes via splits.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    let serverId: UUID
    var title: String
    var createdAt: Date

    /// The split layout for this tab. Nil means single pane (the root pane).
    var layout: TerminalSplitNode?

    /// The currently focused pane ID within this tab
    var focusedPaneId: UUID

    /// Root pane ID - the original pane created with this tab
    let rootPaneId: UUID

    init(
        id: UUID = UUID(),
        serverId: UUID,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serverId = serverId
        self.title = title
        self.createdAt = createdAt
        self.rootPaneId = UUID()
        self.focusedPaneId = rootPaneId
        self.layout = nil
    }

    /// All pane IDs in this tab (from layout or just root)
    var allPaneIds: [UUID] {
        layout?.allPaneIds() ?? [rootPaneId]
    }

    /// Number of panes in this tab
    var paneCount: Int {
        layout?.leafCount ?? 1
    }

    /// Whether this tab has splits
    var hasSplits: Bool {
        layout != nil && (layout?.leafCount ?? 1) > 1
    }
}

// MARK: - Terminal Pane State

/// State for a single terminal pane (leaf in split tree)
struct TerminalPaneState {
    let paneId: UUID
    let tabId: UUID
    let serverId: UUID
    var connectionState: ConnectionState
    var lastActivity: Date

    init(paneId: UUID, tabId: UUID, serverId: UUID) {
        self.paneId = paneId
        self.tabId = tabId
        self.serverId = serverId
        self.connectionState = .connecting
        self.lastActivity = Date()
    }
}
