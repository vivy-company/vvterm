import Foundation
import Testing
@testable import VVTerm

struct GhosttyConfigBuilderTests {
    @Test @MainActor
    func appAcceptsResolvedAppearanceBeforeStartup() {
        let lightTheme = ResolvedTerminalTheme(
            name: "Injected Light",
            palette: .fallback
        )
        let darkTheme = ResolvedTerminalTheme(
            name: "Injected Dark",
            palette: .fallback
        )
        let initial = TerminalAppearanceSnapshot(
            activeAppearance: .dark,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
        let updated = TerminalAppearanceSnapshot(
            activeAppearance: .light,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
        let app = GhosttyRuntime(appearance: initial, autoStart: false)

        app.applyAppearance(updated)

        #expect(app.readiness == .idle)
        #expect(app.appearanceSnapshot == updated)
    }

    #if os(macOS)
    @Test
    func macOSConfigContentMapsOptionAsAltModesToGhosttyValues() {
        let expectedValues: [(TerminalOptionAsAltMode, String)] = [
            (.none, "false"),
            (.left, "left"),
            (.right, "right"),
            (.both, "true")
        ]

        for (mode, expectedValue) in expectedValues {
            let content = Ghostty.ConfigBuilder.configContent(
                fontSelection: selection("Menlo"),
                fontSize: 13,
                shellName: "fish",
                theme: "Aizen Light",
                optionAsAltMode: mode
            )

            #expect(content.contains("macos-option-as-alt = \(expectedValue)"))
        }
    }

    #endif

    @Test(arguments: ["JetBrainsMono Nerd Font", "Hack Nerd Font", "A\"B\\C\nD\rE"],
          [nil, "Apple SD Gothic Neo"] as [String?])
    func styledTextUsesPrimaryFamilyInsteadOfCJKFallback(primaryFamily: String, cjkFamily: String?) {
        let content = Ghostty.ConfigBuilder.configContent(
            fontSelection: selection(primaryFamily, cjk: cjkFamily),
            fontSize: 15,
            shellName: "fish",
            theme: "Aizen Dark"
        )
        let primary = Ghostty.ConfigBuilder.escapedFontFamilyValue(primaryFamily)
        let lines = content.split(separator: "\n").map(String.init)

        for style in ["bold", "italic", "bold-italic"] {
            let key = "font-family-\(style) ="
            #expect(lines.filter { $0.hasPrefix(key) } == ["\(key) \"\(primary)\""])
        }
        #if os(macOS)
        #expect(lines.contains("font-family = \"Apple SD Gothic Neo\""))
        #else
        if cjkFamily != nil {
            #expect(lines.contains("font-family = \"Apple SD Gothic Neo\""))
        }
        #endif
        #expect(content.contains("font-codepoint-map =") == (cjkFamily != nil))
    }

    @Test
    func fontFamilyLinesPreserveOrderedFallbackStack() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines([
            "Menlo",
            "Noto Sans CJK",
            "JetBrainsMono Nerd Font"
        ])
            .split(separator: "\n")
            .map(String.init)

        #expect(lines == [
            "font-family = \"Menlo\"",
            "font-family = \"Noto Sans CJK\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
    }

    @Test
    func fontFamilyLinesTrimWhitespaceAndDeduplicateFamilies() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines([
            "  Noto Sans CJK  ",
            "Noto Sans CJK",
            "JetBrainsMono Nerd Font"
        ])
            .split(separator: "\n")
            .map(String.init)

        #expect(lines == [
            "font-family = \"Noto Sans CJK\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
    }

    @Test
    func fontFamilyLinesIgnoreBlankFamilies() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(["   \n  "])
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.isEmpty)
    }

    @Test
    func fontFamilyLinesEscapeQuotesBackslashesAndNewlines() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(["A\"B\\C\nD\rE"])
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.first == "font-family = \"A\\\"B\\\\CDE\"")
    }

    @Test
    func cjkCodepointMapCoversCJKHangulAndSupplementaryPlanes() {
        let line = Ghostty.ConfigBuilder.fontCodepointMapLine(cjkFamily: "Noto Sans CJK")

        #expect(line.contains("U+1100-U+11FF"))
        #expect(line.contains("U+4E00-U+9FFF"))
        #expect(line.contains("U+AC00-U+D7AF"))
        #expect(line.contains("U+20000-U+2FA1F"))
        #expect(line.contains("U+30000-U+323AF"))
        #expect(line.hasSuffix("=Noto Sans CJK\""))
    }

    @Test
    func cjkCodepointMapIgnoresBlankAndEscapesUnsafeCharacters() {
        #expect(Ghostty.ConfigBuilder.fontCodepointMapLine(cjkFamily: nil).isEmpty)
        #expect(Ghostty.ConfigBuilder.fontCodepointMapLine(cjkFamily: " \n ").isEmpty)

        let line = Ghostty.ConfigBuilder.fontCodepointMapLine(
            cjkFamily: "A\"B\\C\nD\rE"
        )
        #expect(line.hasSuffix("=A\\\"B\\\\CDE\""))
    }

    @Test
    func configContentKeepsNonFontLinesStable() {
        let content = Ghostty.ConfigBuilder.configContent(
            fontSelection: selection("Menlo", cjk: "Noto Sans CJK"),
            fontSize: 13,
            shellName: "fish",
            theme: "Aizen Light"
        )

        #expect(content.contains("font-size = 13"))
        #expect(content.contains("window-inherit-font-size = false"))
        #expect(content.contains("window-padding-x = 0"))
        #expect(content.contains("window-padding-y = 0"))
        #expect(content.contains("shell-integration = fish"))
        #expect(content.contains("theme = Aizen Light"))
        #expect(content.contains("cursor-style = block"))
        #expect(content.contains("cursor-style-blink = true"))
        #expect(content.contains("keybind = shift+enter=text:\\n"))
        #expect(content.contains("clipboard-read = allow"))
        #expect(content.contains("clipboard-write = allow"))
        #expect(content.contains("font-codepoint-map ="))
    }

    @Test
    func configContentIncludesContentPadding() {
        let content = Ghostty.ConfigBuilder.configContent(
            fontSelection: selection("Menlo"),
            fontSize: 13,
            contentPadding: TerminalContentPadding(horizontal: 12, vertical: 18),
            shellName: "fish",
            theme: "Aizen Light"
        )

        #expect(content.contains("window-padding-x = 12"))
        #expect(content.contains("window-padding-y = 18"))
        #expect(content.split(separator: "\n").contains("window-padding-color = extend"))
    }

    @Test
    func configContentIncludesCursorSettings() {
        let content = Ghostty.ConfigBuilder.configContent(
            fontSelection: selection("Menlo"),
            fontSize: 13,
            shellName: "fish",
            theme: "Aizen Light",
            cursorStyle: .bar,
            cursorBlink: false
        )

        #expect(content.contains("cursor-style = bar"))
        #expect(content.contains("cursor-style-blink = false"))
    }

    @Test
    func configContentUsesEachRemoteClipboardPolicy() {
        for policy in TerminalRemoteClipboardPolicy.allCases {
            let content = Ghostty.ConfigBuilder.configContent(
                fontSelection: selection("Menlo"),
                fontSize: 13,
                shellName: "fish",
                theme: "Aizen Light",
                remoteClipboardPolicy: policy
            )

            #expect(content.contains("clipboard-read = \(policy.rawValue)"))
            #expect(content.contains("clipboard-write = \(policy.rawValue)"))
        }
    }

    private func selection(
        _ primaryFamily: String,
        cjk: String? = nil
    ) -> TerminalFontRuntimeSelection {
        TerminalFontRuntimeSelection(
            primaryFamily: primaryFamily,
            cjkFamily: cjk
        )
    }

    @Test
    func ghosttyClipboardRequestsMapToExplicitPrompts() {
        #expect(
            GhosttyRuntime.clipboardConfirmationKind(
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
            ) == .remoteRead
        )
        #expect(
            GhosttyRuntime.clipboardConfirmationKind(
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE
            ) == .remoteWrite
        )
        #expect(
            GhosttyRuntime.clipboardConfirmationKind(
                request: GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ
            ) == .remoteRead
        )
        #expect(
            GhosttyRuntime.clipboardConfirmationKind(
                request: GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE
            ) == .remoteWrite
        )
        #expect(
            GhosttyRuntime.clipboardConfirmationKind(
                request: GHOSTTY_CLIPBOARD_REQUEST_LIST
            ) == .remoteRead
        )
        #expect(
            GhosttyRuntime.clipboardConfirmationKind(
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE
            ) == .unsafePaste
        )
    }
}
