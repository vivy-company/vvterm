import Foundation

nonisolated enum TerminalThemeValidationError: Error {
    case emptyContent
    case invalidLine(line: Int)
    case invalidHex(line: Int)
    case invalidPalette(line: Int)
    case invalidValue(line: Int, key: String)
    case unsupportedKey(line: Int, key: String)
    case missingRequiredKey(String)
    case invalidName
    case themeNotFound

}

nonisolated enum TerminalThemeValidator {
    static let maximumNameLength = 80

    /// The visual-only subset of Ghostty's theme configuration contract.
    /// Theme files are full Ghostty config files, so every allowed key must be
    /// listed here to prevent a theme from changing commands or app behavior.
    private enum SafeThemeKey: String {
        case background
        case foreground
        case cursorColor = "cursor-color"
        case cursorText = "cursor-text"
        case selectionBackground = "selection-background"
        case selectionForeground = "selection-foreground"
        case boldColor = "bold-color"
        case splitDividerColor = "split-divider-color"
        case unfocusedSplitFill = "unfocused-split-fill"
        case palette
        case paletteGenerate = "palette-generate"
        case paletteHarmonious = "palette-harmonious"
        case backgroundOpacity = "background-opacity"
        case backgroundOpacityCells = "background-opacity-cells"
        case cursorOpacity = "cursor-opacity"
        case faintOpacity = "faint-opacity"
        case unfocusedSplitOpacity = "unfocused-split-opacity"
        case minimumContrast = "minimum-contrast"

        var valueRule: ValueRule {
            switch self {
            case .background, .foreground, .cursorColor, .cursorText,
                 .selectionBackground, .selectionForeground, .boldColor,
                 .splitDividerColor, .unfocusedSplitFill:
                return .color(allowsEmpty: self != .background && self != .foreground)
            case .palette:
                return .palette
            case .paletteGenerate, .paletteHarmonious, .backgroundOpacityCells:
                return .boolean
            case .backgroundOpacity, .cursorOpacity, .faintOpacity:
                return .number(0...1)
            case .unfocusedSplitOpacity:
                return .number(0.15...1)
            case .minimumContrast:
                return .number(1...21)
            }
        }
    }

    private enum ValueRule {
        case color(allowsEmpty: Bool)
        case palette
        case boolean
        case number(ClosedRange<Double>)
    }

    nonisolated static func validateAndNormalizeThemeName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name == rawName,
              name.count <= maximumNameLength,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TerminalThemeValidationError.invalidName
        }
        return name
    }

    nonisolated static func validateAndNormalizeTheme(_ theme: TerminalTheme) throws -> TerminalTheme {
        TerminalTheme(
            id: theme.id,
            name: try validateAndNormalizeThemeName(theme.name),
            content: try validateAndNormalizeThemeContent(theme.content),
            updatedAt: theme.updatedAt,
            deletedAt: theme.deletedAt
        )
    }

    /// Validates a stored record without rewriting its original content.
    nonisolated static func validateStoredTheme(_ theme: TerminalTheme) throws -> TerminalTheme {
        _ = try validateAndNormalizeThemeName(theme.name)
        if !theme.isDeleted {
            _ = try validateAndNormalizeThemeContent(theme.content)
        }
        return theme
    }

    nonisolated static func isValidHexColor(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        guard hex.count == 6 else { return false }
        return hex.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0)
        }
    }

    nonisolated static func normalizeHexColor(_ value: String) -> String? {
        guard isValidHexColor(value) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        return "#\(hex.uppercased())"
    }

    private nonisolated static func normalizeColor(_ value: String, allowsEmpty: Bool) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allowsEmpty ? "" : nil
        }
        if let hex = normalizeHexColor(trimmed) {
            return hex
        }

        let semanticColors = Set(["cell-background", "cell-foreground"])
        if semanticColors.contains(trimmed) {
            return trimmed
        }

        // Ghostty supports X11 color names. Limit their syntax so a color
        // value cannot become another config directive.
        guard trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-"
              }) else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func normalizeNumber(
        _ value: String,
        allowedRange: ClosedRange<Double>
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed),
              number.isFinite,
              allowedRange.contains(number) else {
            return nil
        }
        return trimmed
    }

    nonisolated static func validateAndNormalizeThemeContent(_ rawContent: String) throws -> String {
        let lines = rawContent.components(separatedBy: .newlines)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TerminalThemeValidationError.emptyContent
        }

        var normalizedLines: [String] = []
        var seenBackground = false
        var seenForeground = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw TerminalThemeValidationError.invalidLine(line: lineNumber)
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            guard let safeKey = SafeThemeKey(rawValue: key) else {
                throw TerminalThemeValidationError.unsupportedKey(line: lineNumber, key: key)
            }

            switch safeKey.valueRule {
            case .palette:
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                guard paletteParts.count == 2,
                      let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      (0...255).contains(index),
                      let color = normalizeHexColor(String(paletteParts[1])) else {
                    throw TerminalThemeValidationError.invalidPalette(line: lineNumber)
                }
                normalizedLines.append("palette = \(index)=\(color)")
            case .color(let allowsEmpty):
                guard let color = normalizeColor(value, allowsEmpty: allowsEmpty) else {
                    throw TerminalThemeValidationError.invalidHex(line: lineNumber)
                }
                normalizedLines.append("\(key) = \(color)")

                if key == "background" { seenBackground = true }
                if key == "foreground" { seenForeground = true }
            case .boolean:
                guard value == "true" || value == "false" else {
                    throw TerminalThemeValidationError.invalidValue(line: lineNumber, key: key)
                }
                normalizedLines.append("\(key) = \(value)")
            case .number(let range):
                guard let number = normalizeNumber(value, allowedRange: range) else {
                    throw TerminalThemeValidationError.invalidValue(line: lineNumber, key: key)
                }
                normalizedLines.append("\(key) = \(number)")
            }
        }

        guard seenBackground else {
            throw TerminalThemeValidationError.missingRequiredKey("background")
        }
        guard seenForeground else {
            throw TerminalThemeValidationError.missingRequiredKey("foreground")
        }

        return normalizedLines.joined(separator: "\n") + "\n"
    }
}
