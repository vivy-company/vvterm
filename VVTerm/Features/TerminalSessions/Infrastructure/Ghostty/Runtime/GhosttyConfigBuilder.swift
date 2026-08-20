import Foundation

extension Ghostty {
    nonisolated enum ConfigBuilder {
        static func sanitizedFontFamilies(primaryFamily: String) -> [String] {
            #if os(macOS)
            let candidates = [primaryFamily] + TerminalDefaults.macOSFallbackFontFamilies
            #else
            let candidates = [primaryFamily]
            #endif

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

        static func fontFamilyLines(primaryFamily: String) -> String {
            sanitizedFontFamilies(primaryFamily: primaryFamily)
                .map { "font-family = \"\(escapedFontFamilyValue($0))\"" }
                .joined(separator: "\n")
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
            primaryFontFamily: String,
            fontSize: Double,
            shellName: String,
            themeName: String,
            cursorStyle: TerminalCursorStyle = TerminalDefaults.defaultCursorStyle,
            cursorBlink: Bool = TerminalDefaults.defaultCursorBlink,
            optionAsAltMode: TerminalOptionAsAltMode = .none,
            remoteClipboardReadPolicy: TerminalRemoteClipboardReadPolicy = .defaultValue
        ) -> String {
            #if os(macOS)
            let platformInputConfig = "macos-option-as-alt = \(optionAsAltConfigValue(optionAsAltMode))"
            #else
            let platformInputConfig = ""
            #endif

            return """
            \(fontFamilyLines(primaryFamily: primaryFontFamily))
            font-size = \(Int(fontSize))
            window-inherit-font-size = false
            window-padding-balance = false
            window-padding-x = 0
            window-padding-y = 0
            window-padding-color = extend-always

            # Enable shell integration (resources dir auto-detected from app bundle)
            shell-integration = \(shellName)
            shell-integration-features = no-cursor,sudo,title

            # Cursor
            cursor-style = \(cursorStyle.rawValue)
            cursor-style-blink = \(cursorBlink ? "true" : "false")

            theme = \(themeName)

            # Disable audible bell
            audible-bell = false

            # Remote clipboard access uses Ghostty's supported consent policy.
            clipboard-read = \(remoteClipboardReadPolicy.rawValue)
            clipboard-write = ask

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
