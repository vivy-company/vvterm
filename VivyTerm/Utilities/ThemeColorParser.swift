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
    static func backgroundColor(for themeName: String) -> Color? {
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
}
