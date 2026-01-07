//
//  Ghostty.Action.swift
//  aizen
//
//  Action types for Ghostty terminal events
//

import Foundation

// MARK: - Ghostty.Action

extension Ghostty {
    enum Action {}
}

// MARK: - Scrollbar

extension Ghostty.Action {
    /// Represents the scrollbar state from the terminal core.
    ///
    /// ## Fields
    /// - `total`: Total rows in scrollback + active area
    /// - `offset`: First visible row (0 = top of history)
    /// - `len`: Number of visible rows (viewport height)
    struct Scrollbar {
        let total: UInt64
        let offset: UInt64
        let len: UInt64

        init(c: ghostty_action_scrollbar_s) {
            total = c.total
            offset = c.offset
            len = c.len
        }

        init(total: UInt64, offset: UInt64, len: UInt64) {
            self.total = total
            self.offset = offset
            self.len = len
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the terminal scrollbar state changes.
    /// userInfo contains ScrollbarKey with Ghostty.Action.Scrollbar value.
    static let ghosttyDidUpdateScrollbar = Notification.Name("win.aizen.app.ghostty.didUpdateScrollbar")

    /// Key for scrollbar state in notification userInfo
    static let ScrollbarKey = ghosttyDidUpdateScrollbar.rawValue + ".scrollbar"
}
