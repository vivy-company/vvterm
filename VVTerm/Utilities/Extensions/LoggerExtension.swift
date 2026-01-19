//
//  LoggerExtension.swift
//  aizen
//
//  Unified logging utility for the application
//

import Foundation
import os.log

extension Logger {
    /// The app's logging subsystem - must match bundle identifier for proper filtering
    nonisolated private static let appSubsystem = Bundle.main.bundleIdentifier ?? "win.aizen.app"

    /// Create a logger for a specific category
    nonisolated static func forCategory(_ category: String) -> Logger {
        Logger(subsystem: appSubsystem, category: category)
    }

    /// Convenience logger instances for common categories
    nonisolated static let agent = Logger.forCategory("Agent")
    nonisolated static let git = Logger.forCategory("Git")
    nonisolated static let terminal = Logger.forCategory("Terminal")
    nonisolated static let chat = Logger.forCategory("Chat")
    nonisolated static let workspace = Logger.forCategory("Workspace")
    nonisolated static let worktree = Logger.forCategory("Worktree")
    nonisolated static let settings = Logger.forCategory("Settings")
    nonisolated static let audio = Logger.forCategory("Audio")
    nonisolated static let acp = Logger.forCategory("ACP")
    nonisolated static let crash = Logger.forCategory("CrashReporter")
}
