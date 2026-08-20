import CoreGraphics
import Testing
@testable import VVTerm

struct TerminalAccessoryAppearancePolicyTests {
    @Test
    func ownerAppearanceOverridesDetachedInputHostAppearance() {
        #expect(
            TerminalAccessoryAppearancePolicy.resolvedInterfaceStyle(
                owner: .dark,
                host: .light
            ) == .dark
        )
        #expect(
            TerminalAccessoryAppearancePolicy.resolvedInterfaceStyle(
                owner: .light,
                host: .dark
            ) == .light
        )
    }

    @Test
    func hostAppearanceIsFallbackWhenOwnerIsUnspecified() {
        #expect(
            TerminalAccessoryAppearancePolicy.resolvedInterfaceStyle(
                owner: .unspecified,
                host: .dark
            ) == .dark
        )
    }

    @Test
    func classifiesThemeBackgroundLuminance() {
        #expect(TerminalAccessoryAppearancePolicy.isDarkBackground(
            red: 0.04,
            green: 0.05,
            blue: 0.06
        ))
        #expect(!TerminalAccessoryAppearancePolicy.isDarkBackground(
            red: 0.95,
            green: 0.96,
            blue: 0.97
        ))
    }
}
