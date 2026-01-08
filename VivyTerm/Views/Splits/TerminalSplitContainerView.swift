//
//  TerminalSplitContainerView.swift
//  VivyTerm
//
//  Split menu commands and focused values for terminal splits (macOS only)
//

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Split Menu Commands

struct SplitCommands: Commands {
    @FocusedValue(\.activeServerId) var activeServerId
    @FocusedValue(\.activePaneId) var activePaneId
    @FocusedValue(\.terminalSplitActions) var splitActions

    var body: some Commands {
        CommandMenu("Terminal") {
            Group {
                Button("Split Right") {
                    splitActions?.splitHorizontal()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!canSplit)

                Button("Split Down") {
                    splitActions?.splitVertical()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!canSplit)

                Divider()

                Button("Close Pane") {
                    splitActions?.closePane()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!hasActivePane)
            }
        }
    }

    private var canSplit: Bool {
        guard StoreManager.shared.isPro else { return false }
        return splitActions != nil && activePaneId != nil
    }

    private var hasActivePane: Bool {
        activePaneId != nil && splitActions != nil
    }
}

// MARK: - Split Actions

/// Actions that can be performed on a terminal split layout
struct TerminalSplitActions {
    let splitHorizontal: () -> Void
    let splitVertical: () -> Void
    let closePane: () -> Void
}

// MARK: - Focused Values

struct ActiveServerIdKey: FocusedValueKey {
    typealias Value = UUID
}

struct ActivePaneIdKey: FocusedValueKey {
    typealias Value = UUID
}

struct TerminalSplitActionsKey: FocusedValueKey {
    typealias Value = TerminalSplitActions
}

extension FocusedValues {
    var activeServerId: UUID? {
        get { self[ActiveServerIdKey.self] }
        set { self[ActiveServerIdKey.self] = newValue }
    }

    var activePaneId: UUID? {
        get { self[ActivePaneIdKey.self] }
        set { self[ActivePaneIdKey.self] = newValue }
    }

    var terminalSplitActions: TerminalSplitActions? {
        get { self[TerminalSplitActionsKey.self] }
        set { self[TerminalSplitActionsKey.self] = newValue }
    }
}

#endif
