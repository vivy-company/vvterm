//
//  Ghostty+Action.swift
//  VVTerm
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
    nonisolated struct Scrollbar: Sendable {
        let total: UInt64
        let offset: UInt64
        let len: UInt64

        init(c: ghostty_action_scrollbar_s) {
            self.init(total: c.total, offset: c.offset, len: c.len)
        }

        init(total: UInt64, offset: UInt64, len: UInt64) {
            self.total = total
            self.len = min(len, total)
            self.offset = min(offset, total - self.len)
        }

        var rowsBelowViewport: UInt64 {
            total - offset - len
        }

        var offsetAsInt: Int {
            Int(clamping: offset)
        }

        static func clampedRowIndex(_ value: Double) -> Int? {
            guard value.isFinite else { return nil }
            let row = floor(value)
            guard row > 0 else { return 0 }
            return Int(exactly: row) ?? Int.max
        }
    }
}

// MARK: - Notification Names

nonisolated extension Notification.Name {
    /// Posted when the terminal scrollbar state changes.
    /// userInfo contains ScrollbarKey with Ghostty.Action.Scrollbar value.
    static let ghosttyDidUpdateScrollbar = Notification.Name("app.vivy.VivyTerm.ghostty.didUpdateScrollbar")

    /// Key for scrollbar state in notification userInfo
    static let ScrollbarKey = ghosttyDidUpdateScrollbar.rawValue + ".scrollbar"
}
