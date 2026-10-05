import Foundation

extension Ghostty {
    nonisolated enum ConfigBuilder {
        private static let cjkCodepointRanges = [
            "U+1100-U+11FF",
            "U+2E80-U+4DBF",
            "U+4E00-U+9FFF",
            "U+A960-U+A97F",
            "U+AC00-U+D7AF",
            "U+D7B0-U+D7FF",
            "U+F900-U+FAFF",
            "U+FE10-U+FE1F",
            "U+FE30-U+FE4F",
            "U+FF00-U+FFEF",
            "U+1AFF0-U+1AFFF",
            "U+1B000-U+1B16F",
            "U+20000-U+2FA1F",
            "U+30000-U+323AF"
        ]

        static func sanitizedFontFamilies(_ candidates: [String]) -> [String] {
            var seen = Set<String>()
            var families: [String] = []

            for candidate in candidates {
                let family = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !family.isEmpty else { continue }
                guard seen.insert(family).inserted else { continue }
                families.append(family)
            }

            return families
        }

        static func escapedFontFamilyValue(_ family: String) -> String {
            family
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        static func fontFamilyLines(_ families: [String]) -> String {
            sanitizedFontFamilies(families)
                .map { "font-family = \"\(escapedFontFamilyValue($0))\"" }
                .joined(separator: "\n")
        }

        static func fontCodepointMapLine(cjkFamily: String?) -> String {
            guard let cjkFamily else { return "" }
            let family = cjkFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !family.isEmpty else { return "" }

            let ranges = cjkCodepointRanges.joined(separator: ",")
            return "font-codepoint-map = \"\(ranges)=\(escapedFontFamilyValue(family))\""
        }

        static func optionAsAltConfigValue(_ mode: TerminalOptionAsAltMode) -> String {
            switch mode {
            case .none: "false"
            case .left: "left"
            case .right: "right"
            case .both: "true"
            }
        }

        static func configContent(
            fontSelection: TerminalFontRuntimeSelection,
            fontSize: Double,
            contentPadding: TerminalContentPadding = .defaultValue,
            shellName: String,
            theme: String,
            cursorStyle: TerminalCursorStyle = TerminalDefaults.defaultCursorStyle,
            cursorBlink: Bool = TerminalDefaults.defaultCursorBlink,
            optionAsAltMode: TerminalOptionAsAltMode = .none,
            remoteClipboardPolicy: TerminalRemoteClipboardPolicy = .defaultValue
        ) -> String {
            #if os(macOS)
            let platformInputConfig = "macos-option-as-alt = \(optionAsAltConfigValue(optionAsAltMode))"
            #else
            let platformInputConfig = ""
            #endif

            let primaryFamily = escapedFontFamilyValue(fontSelection.primaryFamily)

            return """
            \(fontFamilyLines(fontSelection.fontFamilies))
            # Keep fallback fonts from replacing the primary family's missing styles.
            font-family-bold = "\(primaryFamily)"
            font-family-italic = "\(primaryFamily)"
            font-family-bold-italic = "\(primaryFamily)"
            \(fontCodepointMapLine(cjkFamily: fontSelection.cjkFamily))
            font-size = \(Int(fontSize))
            window-inherit-font-size = false
            window-padding-balance = false
            window-padding-x = \(contentPadding.horizontal)
            window-padding-y = \(contentPadding.vertical)
            # Keep colored prompts out of the space below the last row.
            window-padding-color = extend

            # Enable shell integration (resources dir auto-detected from app bundle)
            shell-integration = \(shellName)
            shell-integration-features = no-cursor,sudo,title

            # Cursor
            cursor-style = \(cursorStyle.rawValue)
            cursor-style-blink = \(cursorBlink ? "true" : "false")

            theme = \(theme)

            # Disable audible bell
            audible-bell = false

            # Remote clipboard access uses Ghostty's supported consent policy.
            clipboard-read = \(remoteClipboardPolicy.rawValue)
            clipboard-write = \(remoteClipboardPolicy.rawValue)

            # Limit scrollback to prevent unbounded memory growth
            # 10000 lines is plenty for most use cases (~5-10MB)
            scrollback-limit = 10000

            # Faster scroll speed (especially for iOS touch)
            mouse-scroll-multiplier = 3

            # Custom keybinds
            keybind = shift+enter=text:\\n

            \(platformInputConfig)

            """
        }
    }
}
