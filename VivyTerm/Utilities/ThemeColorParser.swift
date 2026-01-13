//
//  ThemeColorParser.swift
//  VivyTerm
//

import SwiftUI
import Foundation

/// Parses terminal theme files to extract colors
struct ThemeColorParser {
    /// Extracts background color from a Ghostty theme file
    /// - Parameter themeName: The name of the theme (e.g., "Aizen Dark")
    /// - Returns: The background Color if found, nil otherwise
    nonisolated static func backgroundColor(for themeName: String) -> Color? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        // Try structured path first
        let structuredThemesPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        var themeFile = (structuredThemesPath as NSString).appendingPathComponent(themeName)

        // Fall back to temp directory where themes are copied at runtime
        if !FileManager.default.fileExists(atPath: themeFile) {
            let tempThemesPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ghostty_themes")
            themeFile = (tempThemesPath as NSString).appendingPathComponent(themeName)
        }

        // Fall back to flattened resources (theme file directly in bundle)
        if !FileManager.default.fileExists(atPath: themeFile) {
            themeFile = (resourcePath as NSString).appendingPathComponent(themeName)
        }

        // Try temp config directory
        if !FileManager.default.fileExists(atPath: themeFile) {
            let tempDir = NSTemporaryDirectory()
            let ghosttyConfigDir = (tempDir as NSString).appendingPathComponent(".config/ghostty/themes")
            themeFile = (ghosttyConfigDir as NSString).appendingPathComponent(themeName)
        }

        guard let content = try? String(contentsOfFile: themeFile, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("background") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let colorHex = parts[1].trimmingCharacters(in: .whitespaces)
                    return Color.fromHex(colorHex)
                }
            }
        }

        return nil
    }

    /// Computes the split divider color based on the background color
    /// Uses Ghostty's algorithm: darken by 8% for light backgrounds, 40% for dark
    nonisolated static func splitDividerColor(for themeName: String) -> Color {
        guard let bgColor = backgroundColor(for: themeName) else {
            return Color(white: 0.3)
        }

        #if os(macOS)
        let nsColor = NSColor(bgColor)
        let brightness = nsColor.brightnessComponent
        let isLight = brightness > 0.5

        // Darken by 8% for light, 40% for dark (matching Ghostty)
        let factor = isLight ? 0.92 : 0.6
        let adjusted = NSColor(
            hue: nsColor.hueComponent,
            saturation: nsColor.saturationComponent,
            brightness: nsColor.brightnessComponent * factor,
            alpha: nsColor.alphaComponent
        )
        return Color(adjusted)
        #else
        // iOS fallback
        return Color(white: 0.3)
        #endif
    }
}
