import Foundation
import Testing
@testable import VVTerm

struct GhosttyConfigBuilderTests {
    #if os(macOS)
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
        #expect(content.contains("keybind = shift+enter=text:\\n"))
    }
}
