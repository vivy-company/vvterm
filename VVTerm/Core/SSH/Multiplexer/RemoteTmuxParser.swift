import Foundation

nonisolated enum RemoteTmuxParser {
    static func classifyAvailabilityOutput(
        _ output: String,
        availableMarker: String,
        missingMarker: String,
        backend: RemoteTmuxBackend
    ) -> RemoteTmuxAvailability {
        let reportsAvailable = output.contains(availableMarker)
        let reportsMissing = output.contains(missingMarker)
        switch (reportsAvailable, reportsMissing) {
        case (true, false):
            return .available(backend)
        case (false, true):
            return .confirmedMissing
        case (false, false), (true, true):
            return .indeterminate(.invalidResponse)
        }
    }

    static func parseSessionListOutput(
        _ output: String,
        allowLegacy: Bool
    ) -> [RemoteTmuxSession] {
        var sessions: [RemoteTmuxSession] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if let parsed = parseSessionLine(line) {
                sessions.append(
                    RemoteTmuxSession(
                        name: parsed.name,
                        attachedClients: parsed.attachedClients,
                        windowCount: parsed.windowCount
                    )
                )
                continue
            }
            if allowLegacy, let parsed = parseLegacySessionLine(line) {
                sessions.append(parsed)
            }
        }
        return sortSessions(sessions)
    }

    private static func parseSessionLine(
        _ line: String
    ) -> (name: String, attachedClients: Int, windowCount: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.replacingOccurrences(of: "\\t", with: "\t")
        if let parsed = parseTabSeparatedSessionLine(normalized) {
            return parsed
        }

        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !parts.isEmpty else { return nil }

        if parts.count >= 3,
           let attached = parseAttachedClients(String(parts[parts.count - 2])),
           let windows = Int(parts[parts.count - 1]) {
            let name = parts[0..<(parts.count - 2)]
                .map(String.init)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, max(0, attached), max(1, windows))
        }

        if parts.count >= 2,
           let attached = parseAttachedClients(String(parts[parts.count - 1])) {
            let name = parts[0..<(parts.count - 1)]
                .map(String.init)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, max(0, attached), 1)
        }

        return nil
    }

    private static func parseTabSeparatedSessionLine(
        _ line: String
    ) -> (name: String, attachedClients: Int, windowCount: Int)? {
        guard line.contains("\t") else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let attachedClients: Int
        if parts.count >= 2 {
            attachedClients = parseAttachedClients(String(parts[1])) ?? 0
        } else {
            attachedClients = 0
        }

        let windowCount: Int
        if parts.count >= 3 {
            windowCount = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        } else {
            windowCount = 1
        }

        return (name, max(0, attachedClients), max(1, windowCount))
    }

    private static func parseAttachedClients(_ rawValue: String) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let count = Int(value) {
            return count
        }

        switch value.lowercased() {
        case "true", "yes", "attached":
            return 1
        case "false", "no", "detached":
            return 0
        default:
            return nil
        }
    }

    private static func parseLegacySessionLine(_ line: String) -> RemoteTmuxSession? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }

        let name = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let remainder = trimmed[trimmed.index(after: colonIndex)...]
        let tokens = remainder.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
        let firstNumericToken = tokens.first(where: { Int($0) != nil })
        let windows = firstNumericToken.flatMap { Int($0) } ?? 1
        let attached = trimmed.contains("(attached)") ? 1 : 0

        return RemoteTmuxSession(
            name: name,
            attachedClients: max(0, attached),
            windowCount: max(1, windows)
        )
    }

    private static func sortSessions(_ sessions: [RemoteTmuxSession]) -> [RemoteTmuxSession] {
        sessions.sorted { lhs, rhs in
            if lhs.attachedClients != rhs.attachedClients {
                return lhs.attachedClients > rhs.attachedClients
            }
            if lhs.windowCount != rhs.windowCount {
                return lhs.windowCount > rhs.windowCount
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
