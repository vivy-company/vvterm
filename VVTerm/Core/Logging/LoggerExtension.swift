//
//  LoggerExtension.swift
//  VVTerm
//
//  Unified logging utility for the application
//

import Foundation
import os.log

extension Logger {
    /// The app's logging subsystem - must match bundle identifier for proper filtering
    nonisolated private static let appSubsystem = Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm"

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

enum DebugLogConfiguration {
    nonisolated static func isEnabled(_ category: String) -> Bool {
        let process = Foundation.ProcessInfo.processInfo
        let requestedCategories = requestedCategories(
            arguments: process.arguments,
            environment: process.environment
        )
        guard !requestedCategories.isEmpty else { return false }

        let normalizedCategory = normalize(category)
        return requestedCategories.contains("*")
            || requestedCategories.contains("all")
            || requestedCategories.contains(normalizedCategory)
    }

    nonisolated private static func requestedCategories(
        arguments: [String],
        environment: [String: String]
    ) -> Set<String> {
        var values: [String] = []
        values.append(contentsOf: argumentValues(named: "--vvterm-debug-log", in: arguments))
        values.append(contentsOf: argumentValues(named: "--vvterm-debug-logs", in: arguments))
        if let environmentValue = environment["VVTERM_DEBUG_LOGS"] {
            values.append(environmentValue)
        }
        return Set(values.flatMap(splitCategories).map(normalize))
    }

    nonisolated private static func argumentValues(named name: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == name {
                let nextIndex = arguments.index(after: index)
                if nextIndex < arguments.endIndex {
                    values.append(arguments[nextIndex])
                    index = arguments.index(after: nextIndex)
                    continue
                }
            } else if argument.hasPrefix("\(name)=") {
                values.append(String(argument.dropFirst(name.count + 1)))
            }
            index = arguments.index(after: index)
        }
        return values
    }

    nonisolated private static func splitCategories(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == " " || $0 == ";" }
            .map(String.init)
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum LogPrivacy {
    nonisolated static func errorClass(_ error: Error) -> String {
        String(reflecting: type(of: error))
    }
}
