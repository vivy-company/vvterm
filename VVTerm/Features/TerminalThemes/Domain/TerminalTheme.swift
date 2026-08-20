//
//  TerminalTheme.swift
//  VVTerm
//

import Foundation

nonisolated struct TerminalTheme: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var content: String
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    var validationState: TerminalThemeValidationState {
        do {
            let content = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
            _ = try TerminalThemeValidator.validateAndNormalizeThemeName(name)
            return .ready(normalizedContent: content)
        } catch {
            return .needsRepair
        }
    }

    var canApply: Bool {
        if case .ready = validationState { return true }
        return false
    }
}

nonisolated enum TerminalThemeValidationState: Equatable, Sendable {
    case ready(normalizedContent: String)
    case needsRepair
}

nonisolated enum TerminalThemeMergePolicy {
    static func merge(local: [TerminalTheme], remote: [TerminalTheme]) -> [TerminalTheme] {
        var themesByID: [UUID: TerminalTheme] = [:]
        for theme in local {
            if let existing = themesByID[theme.id], existing.updatedAt >= theme.updatedAt {
                continue
            }
            themesByID[theme.id] = theme
        }

        for untrustedTheme in remote {
            guard let theme = try? TerminalThemeValidator.validateStoredTheme(untrustedTheme) else {
                continue
            }
            if let existing = themesByID[theme.id], existing.updatedAt >= theme.updatedAt {
                continue
            }
            themesByID[theme.id] = theme
        }
        return Array(themesByID.values)
    }
}

nonisolated struct TerminalThemePreference: Codable, Equatable, Sendable {
    var darkThemeName: String
    var lightThemeName: String
    var usePerAppearanceTheme: Bool
    var updatedAt: Date
}
