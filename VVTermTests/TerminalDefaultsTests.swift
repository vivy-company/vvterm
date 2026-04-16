import Foundation
import Testing
@testable import VVTerm

struct TerminalDefaultsTests {
    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "TerminalDefaultsTests.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test
    func macOSDefaultsExposeMenloAndTwelvePointSize() throws {
        #if os(macOS)
        #expect(TerminalDefaults.defaultFontName == "Menlo")
        #expect(TerminalDefaults.defaultPrimaryFontName == "Menlo")
        #expect(TerminalDefaults.defaultFontSize == 12.0)
        #expect(TerminalDefaults.legacyDefaultFontName == "JetBrainsMono Nerd Font")
        #expect(
            TerminalDefaults.macOSFallbackFontFamilies == ["Apple SD Gothic Neo", "JetBrainsMono Nerd Font"]
        )
        #else
        throw Skip("macOS-only default font policy")
        #endif
    }

    @Test
    func applyIfNeededSeedsUnsetFontDefaults() {
        let defaults = makeDefaults()

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #if os(macOS)
        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == "Menlo")
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 12.0)
        #else
        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == TerminalDefaults.defaultFontName)
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == TerminalDefaults.defaultFontSize)
        #endif
        #expect(defaults.object(forKey: ImagePasteBehavior.userDefaultsKey) as? String == ImagePasteBehavior.askOnce.rawValue)
    }

    @Test
    func applyIfNeededNormalizesBlankFontNameWithoutOverwritingExistingFontSize() {
        let defaults = makeDefaults()

        defaults.set("   \n", forKey: TerminalDefaults.fontNameKey)
        defaults.set(14.0, forKey: TerminalDefaults.fontSizeKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == TerminalDefaults.defaultFontName)
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 14.0)
    }

    @Test
    func applyIfNeededPreservesCustomMacOSFontValues() throws {
        #if os(macOS)
        let defaults = makeDefaults()

        defaults.set("Menlo", forKey: TerminalDefaults.fontNameKey)
        defaults.set(15.0, forKey: TerminalDefaults.fontSizeKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == "Menlo")
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 15.0)
        #else
        throw Skip("macOS-only migration policy")
        #endif
    }

    @Test
    func applyIfNeededPreservesExactLegacyMacOSFontValues() throws {
        #if os(macOS)
        let normalizedFontName = TerminalDefaults.normalizedMacOSFontName(
            storedFontName: TerminalDefaults.legacyDefaultFontName,
            fontValidator: { _ in true }
        )

        #expect(normalizedFontName == TerminalDefaults.legacyDefaultFontName)
        #else
        throw Skip("macOS-only legacy font preservation")
        #endif
    }

    @Test
    func applyIfNeededNormalizesExactLegacyMacOSFontValuesWhenFontIsUnavailable() throws {
        #if os(macOS)
        let normalizedFontName = TerminalDefaults.normalizedMacOSFontName(
            storedFontName: TerminalDefaults.legacyDefaultFontName,
            fontValidator: { _ in false }
        )

        #expect(normalizedFontName == TerminalDefaults.defaultPrimaryFontName)
        #else
        throw Skip("macOS-only legacy font normalization")
        #endif
    }

    @Test
    func applyIfNeededNormalizesInvalidStoredMacOSFontName() throws {
        #if os(macOS)
        let defaults = makeDefaults()

        defaults.set("DefinitelyNotARealFixedPitchFont", forKey: TerminalDefaults.fontNameKey)
        defaults.set(16.0, forKey: TerminalDefaults.fontSizeKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == TerminalDefaults.defaultPrimaryFontName)
        #expect(defaults.object(forKey: TerminalDefaults.fontSizeKey) as? Double == 16.0)
        #else
        throw Skip("macOS-only migration policy")
        #endif
    }
}
