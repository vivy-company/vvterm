//
//  ThemeColorParser.swift
//  VVTerm
//

import SwiftUI
import Foundation

struct TerminalThemePreviewPalette {
    let background: Color
    let foreground: Color
    let cursor: Color
    let cursorText: Color

    static let fallback = TerminalThemePreviewPalette(
        background: Color.fromHex("#101418"),
        foreground: Color.fromHex("#D8E0EA"),
        cursor: Color.fromHex("#F8B26A"),
        cursorText: Color.fromHex("#101418")
    )
}

/// Parses terminal theme files to extract colors
struct ThemeColorParser {
    /// Extracts background color from a Ghostty theme file
    /// - Parameter themeName: The name of the theme (e.g., "Aizen Dark")
    /// - Returns: The background Color if found, nil otherwise
    static func backgroundColor(for themeName: String) -> Color? {
        guard let content = themeContent(for: themeName),
              let colorHex = value(for: "background", in: content) else {
            return nil
        }

        return Color.fromHex(colorHex)
    }

    static func previewPalette(for themeName: String) -> TerminalThemePreviewPalette {
        let palette = appearancePalette(for: themeName)

        return TerminalThemePreviewPalette(
            background: Color.fromHex(palette.backgroundHex),
            foreground: Color.fromHex(palette.foregroundHex),
            cursor: Color.fromHex(palette.cursorHex),
            cursorText: Color.fromHex(palette.cursorTextHex)
        )
    }

    nonisolated static func appearancePalette(for themeName: String) -> TerminalThemePalette {
        guard let content = themeContent(for: themeName) else {
            return .fallback
        }

        return appearancePalette(themeContent: content)
    }

    nonisolated static func appearancePalette(themeContent content: String) -> TerminalThemePalette {
        let fallback = TerminalThemePalette.fallback
        let background = normalizedHexValue(for: "background", in: content) ?? fallback.backgroundHex
        let foreground = normalizedHexValue(for: "foreground", in: content) ?? fallback.foregroundHex
        let cursor = normalizedHexValue(for: "cursor-color", in: content) ?? foreground
        let cursorText = normalizedHexValue(for: "cursor-text", in: content) ?? background

        return TerminalThemePalette(
            backgroundHex: background,
            foregroundHex: foreground,
            cursorHex: cursor,
            cursorTextHex: cursorText
        )
    }

    nonisolated static func splitDividerComponents(
        for backgroundHex: String
    ) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        let hex = backgroundHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard [3, 6, 8].contains(hex.count) else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

        let alpha, red, green, blue: UInt64
        switch hex.count {
        case 3:
            (alpha, red, green, blue) = (
                255,
                (value >> 8) * 17,
                ((value >> 4) & 0xF) * 17,
                (value & 0xF) * 17
            )
        case 6:
            (alpha, red, green, blue) = (
                255,
                value >> 16,
                (value >> 8) & 0xFF,
                value & 0xFF
            )
        default:
            (alpha, red, green, blue) = (
                value >> 24,
                (value >> 16) & 0xFF,
                (value >> 8) & 0xFF,
                value & 0xFF
            )
        }

        let redComponent = Double(red) / 255
        let greenComponent = Double(green) / 255
        let blueComponent = Double(blue) / 255
        let brightness = max(redComponent, max(greenComponent, blueComponent))
        let factor = brightness > 0.5 ? 0.92 : 0.6

        return (
            red: redComponent * factor,
            green: greenComponent * factor,
            blue: blueComponent * factor,
            alpha: Double(alpha) / 255
        )
    }

    /// Returns tmux mode-style string for selection highlighting.
    /// Format: "fg=#RRGGBB,bg=#RRGGBB"
    nonisolated static func tmuxModeStyle(for themeName: String) -> String {
        let fallbackForegroundHex = "cdd6f4"
        let fallbackSelectionBackgroundHex = "45475a"
        guard let content = themeContent(for: themeName) else {
            return "fg=#\(fallbackForegroundHex),bg=#\(fallbackSelectionBackgroundHex)"
        }

        let selectionForeground = value(for: "selection-foreground", in: content)
            .flatMap(TerminalThemeValidator.normalizeHexColor(_:))
        let foreground = value(for: "foreground", in: content)
            .flatMap(TerminalThemeValidator.normalizeHexColor(_:))
        let selectionBackground = value(for: "selection-background", in: content)
            .flatMap(TerminalThemeValidator.normalizeHexColor(_:))

        let fg = normalizeHex(selectionForeground ?? foreground ?? fallbackForegroundHex)
        let bg = normalizeHex(selectionBackground ?? fallbackSelectionBackgroundHex)
        return "fg=#\(fg),bg=#\(bg)"
    }

    private nonisolated struct CachedThemeContent: Sendable {
        let path: String
        let modificationDate: Date?
        let content: String
    }

    private nonisolated(unsafe) static var contentCache: [String: CachedThemeContent] = [:]
    private nonisolated static let contentCacheLock = NSLock()

    nonisolated static func invalidateCache() {
        contentCacheLock.lock()
        contentCache.removeAll()
        contentCacheLock.unlock()
    }

    private nonisolated static func themeContent(for themeName: String) -> String? {
        contentCacheLock.lock()
        defer { contentCacheLock.unlock() }

        if let cached = contentCache[themeName] {
            return cached.content
        }

        guard let themeFile = themeFilePath(for: themeName),
              let content = try? String(contentsOfFile: themeFile, encoding: .utf8) else {
            contentCache.removeValue(forKey: themeName)
            return nil
        }

        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: themeFile))?[.modificationDate] as? Date
        contentCache[themeName] = CachedThemeContent(
            path: themeFile,
            modificationDate: modificationDate,
            content: content
        )
        return content
    }

    private nonisolated static func themeFilePath(for themeName: String) -> String? {
        guard let themeName = try? TerminalThemeValidator.validateAndNormalizeThemeName(themeName) else {
            return nil
        }

        // Try custom themes first.
        if let customThemeFile = TerminalThemeStoragePaths.customThemeFilePath(for: themeName),
           FileManager.default.fileExists(atPath: customThemeFile) {
            return customThemeFile
        }

        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        // Try structured path first
        let structuredThemesPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        let structuredThemeFile = (structuredThemesPath as NSString).appendingPathComponent(themeName)
        if FileManager.default.fileExists(atPath: structuredThemeFile) {
            return structuredThemeFile
        }

        // Fall back to temp directory where themes are copied at runtime
        let tempThemesPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ghostty_themes")
        let tempThemeFile = (tempThemesPath as NSString).appendingPathComponent(themeName)
        if FileManager.default.fileExists(atPath: tempThemeFile) {
            return tempThemeFile
        }

        // Fall back to flattened resources (theme file directly in bundle)
        let flattenedThemeFile = (resourcePath as NSString).appendingPathComponent(themeName)
        if FileManager.default.fileExists(atPath: flattenedThemeFile) {
            return flattenedThemeFile
        }

        // Try temp config directory
        let ghosttyConfigDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(".config/ghostty/themes")
        let configThemeFile = (ghosttyConfigDir as NSString).appendingPathComponent(themeName)
        if FileManager.default.fileExists(atPath: configThemeFile) {
            return configThemeFile
        }

        return nil
    }

    private nonisolated static func value(for key: String, in content: String) -> String? {
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private nonisolated static func normalizedHexValue(
        for key: String,
        in content: String
    ) -> String? {
        value(for: key, in: content)
            .flatMap(TerminalThemeValidator.normalizeHexColor(_:))
    }

    private static func color(for key: String, in content: String) -> Color? {
        guard let colorHex = value(for: key, in: content) else { return nil }
        return Color.fromHex(colorHex)
    }

    private nonisolated static func normalizeHex(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}

@MainActor
struct ThemeColorParserPaletteResolver: TerminalThemePaletteResolving {
    func palette(forThemeNamed name: String) -> TerminalThemePalette {
        ThemeColorParser.appearancePalette(for: name)
    }

    func palette(forThemeContent content: String) -> TerminalThemePalette {
        ThemeColorParser.appearancePalette(themeContent: content)
    }

    func invalidateCache() {
        ThemeColorParser.invalidateCache()
    }
}
