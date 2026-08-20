import Foundation

nonisolated struct TerminalThemeDraft: Equatable, Sendable {
    static let paletteCount = 16

    var background: String
    var foreground: String
    var cursorColor: String
    var cursorText: String
    var selectionBackground: String
    var selectionForeground: String
    var paletteColors: [String]
    var advancedLines: String

    init(
        background: String = "#101418",
        foreground: String = "#D8E0EA",
        cursorColor: String = "#F8B26A",
        cursorText: String = "#101418",
        selectionBackground: String = "#2E3A46",
        selectionForeground: String = "#D8E0EA",
        paletteColors: [String] = Array(repeating: "", count: paletteCount),
        advancedLines: String = ""
    ) {
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.paletteColors = Self.normalizedPalette(paletteColors)
        self.advancedLines = advancedLines
    }

    var hasValidBuilderValues: Bool {
        guard TerminalThemeValidator.isValidHexColor(background),
              TerminalThemeValidator.isValidHexColor(foreground),
              cursorColor.isEmpty || TerminalThemeValidator.isValidHexColor(cursorColor),
              cursorText.isEmpty || TerminalThemeValidator.isValidHexColor(cursorText),
              selectionBackground.isEmpty
                || TerminalThemeValidator.isValidHexColor(selectionBackground),
              selectionForeground.isEmpty
                || TerminalThemeValidator.isValidHexColor(selectionForeground),
              paletteColors.count == Self.paletteCount else {
            return false
        }
        return paletteColors.allSatisfy {
            $0.isEmpty || TerminalThemeValidator.isValidHexColor($0)
        }
    }

    static func decode(_ content: String?) -> Self {
        guard let content, !content.isEmpty else { return Self() }

        var draft = Self()
        var extraLines: [String] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                extraLines.append(trimmed)
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "palette" {
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                guard paletteParts.count == 2,
                      let index = Int(
                        paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                      ),
                      draft.paletteColors.indices.contains(index),
                      let color = TerminalThemeValidator.normalizeHexColor(
                        String(paletteParts[1])
                      ) else {
                    extraLines.append(trimmed)
                    continue
                }
                draft.paletteColors[index] = color
                continue
            }

            let normalized = TerminalThemeValidator.normalizeHexColor(value) ?? value
            switch key {
            case "background":
                draft.background = normalized
            case "foreground":
                draft.foreground = normalized
            case "cursor-color":
                draft.cursorColor = normalized
            case "cursor-text":
                draft.cursorText = normalized
            case "selection-background":
                draft.selectionBackground = normalized
            case "selection-foreground":
                draft.selectionForeground = normalized
            default:
                extraLines.append("\(key) = \(value)")
            }
        }

        draft.advancedLines = extraLines.joined(separator: "\n")
        return draft
    }

    func encodedContent() throws -> String {
        var lines = [
            "background = \(TerminalThemeValidator.normalizeHexColor(background) ?? background)",
            "foreground = \(TerminalThemeValidator.normalizeHexColor(foreground) ?? foreground)"
        ]

        Self.appendColor(cursorColor, key: "cursor-color", to: &lines)
        Self.appendColor(cursorText, key: "cursor-text", to: &lines)
        Self.appendColor(selectionBackground, key: "selection-background", to: &lines)
        Self.appendColor(selectionForeground, key: "selection-foreground", to: &lines)

        for (index, color) in paletteColors.prefix(Self.paletteCount).enumerated() {
            if let value = TerminalThemeValidator.normalizeHexColor(color) {
                lines.append("palette = \(index)=\(value)")
            }
        }

        lines.append(contentsOf: advancedLines.components(separatedBy: .newlines))
        return try TerminalThemeValidator.validateAndNormalizeThemeContent(
            lines.joined(separator: "\n") + "\n"
        )
    }

    private static func appendColor(_ color: String, key: String, to lines: inout [String]) {
        if let value = TerminalThemeValidator.normalizeHexColor(color) {
            lines.append("\(key) = \(value)")
        }
    }

    private static func normalizedPalette(_ colors: [String]) -> [String] {
        Array(colors.prefix(paletteCount))
            + Array(repeating: "", count: max(0, paletteCount - colors.count))
    }
}
