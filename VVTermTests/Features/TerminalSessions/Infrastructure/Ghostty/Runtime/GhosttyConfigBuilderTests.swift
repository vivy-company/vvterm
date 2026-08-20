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
                primaryFontFamily: "Menlo",
                fontSize: 13,
                shellName: "fish",
                themeName: "Aizen Light",
                optionAsAltMode: mode
            )

            #expect(content.contains("macos-option-as-alt = \(expectedValue)"))
        }
    }

    @Test
    func macOSFontFamilyLinesUseDeterministicFallbackStack() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "Menlo")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines == [
            "font-family = \"Menlo\"",
            "font-family = \"Apple SD Gothic Neo\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
    }

    @Test
    func macOSFontFamilyLinesTrimWhitespaceAndDeduplicateFamilies() {
        let appleFallback = TerminalDefaults.macOSFallbackFontFamilies[0]
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "  \(appleFallback)  ")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines == [
            "font-family = \"Apple SD Gothic Neo\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
    }
    #endif

    @Test
    func fontFamilyLinesIgnoreBlankPrimaryFamily() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "   \n  ")
            .split(separator: "\n")
            .map(String.init)

        #if os(macOS)
        #expect(lines == [
            "font-family = \"Apple SD Gothic Neo\"",
            "font-family = \"JetBrainsMono Nerd Font\""
        ])
        #else
        #expect(lines.isEmpty)
        #endif
    }

    @Test
    func fontFamilyLinesEscapeQuotesBackslashesAndNewlines() {
        let lines = Ghostty.ConfigBuilder.fontFamilyLines(primaryFamily: "A\"B\\C\nD\rE")
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.first == "font-family = \"A\\\"B\\\\CDE\"")
    }

    #if os(iOS)
    @Test
    func iOSConfigContentPreservesSingleFamilyBehavior() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "  JetBrainsMono Nerd Font  ",
            fontSize: 9,
            shellName: "zsh",
            themeName: "Aizen Dark"
        )

        let fontFamilyLines = content
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("font-family =") }

        #expect(fontFamilyLines == ["font-family = \"JetBrainsMono Nerd Font\""])
        #expect(!content.contains("macos-option-as-alt"))
    }
    #endif

    @Test
    func configContentKeepsNonFontLinesStable() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "fish",
            themeName: "Aizen Light"
        )

        #expect(content.contains("font-size = 13"))
        #expect(content.contains("window-inherit-font-size = false"))
        #expect(content.contains("shell-integration = fish"))
        #expect(content.contains("theme = Aizen Light"))
        #expect(content.contains("cursor-style = block"))
        #expect(content.contains("cursor-style-blink = true"))
        #expect(content.contains("keybind = shift+enter=text:\\n"))
        #expect(content.contains("clipboard-read = ask"))
        #expect(content.contains("clipboard-write = ask"))
    }

    @Test
    func configContentIncludesCursorSettings() {
        let content = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: "Menlo",
            fontSize: 13,
            shellName: "fish",
            themeName: "Aizen Light",
            cursorStyle: .bar,
            cursorBlink: false
        )

        #expect(content.contains("cursor-style = bar"))
        #expect(content.contains("cursor-style-blink = false"))
    }

    @Test
    func configContentUsesEachRemoteClipboardReadPolicy() {
        for policy in TerminalRemoteClipboardReadPolicy.allCases {
            let content = Ghostty.ConfigBuilder.configContent(
                primaryFontFamily: "Menlo",
                fontSize: 13,
                shellName: "fish",
                themeName: "Aizen Light",
                remoteClipboardReadPolicy: policy
            )

            #expect(content.contains("clipboard-read = \(policy.rawValue)"))
        }
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
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE
            ) == .unsafePaste
        )
    }
}
