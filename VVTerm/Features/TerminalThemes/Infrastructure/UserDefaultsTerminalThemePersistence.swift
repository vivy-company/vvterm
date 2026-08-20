import Foundation

nonisolated struct TerminalThemeUserDefaultsKeys: Equatable, Sendable {
    let customThemes: String
    let darkTheme: String
    let lightTheme: String
    let usesPerAppearanceTheme: String
    let preferenceUpdatedAt: String
    let activeBackgroundCache: String

    static let live = Self(
        customThemes: "terminalCustomThemesV1",
        darkTheme: "terminalThemeName",
        lightTheme: "terminalThemeNameLight",
        usesPerAppearanceTheme: "terminalUsePerAppearanceTheme",
        preferenceUpdatedAt: "terminalThemePreferenceUpdatedAt",
        activeBackgroundCache: "terminalBackgroundColor"
    )
}

@MainActor
final class UserDefaultsTerminalThemePersistence: TerminalThemePersistence {
    private let defaults: UserDefaults
    private let keys: TerminalThemeUserDefaultsKeys

    init(
        defaults: UserDefaults,
        keys: TerminalThemeUserDefaultsKeys
    ) {
        self.defaults = defaults
        self.keys = keys
    }

    func loadCustomThemes() throws -> [TerminalTheme] {
        guard let data = defaults.data(forKey: keys.customThemes) else { return [] }
        return try JSONDecoder().decode([TerminalTheme].self, from: data)
    }

    func saveCustomThemes(_ themes: [TerminalTheme]) throws {
        defaults.set(try JSONEncoder().encode(themes), forKey: keys.customThemes)
    }

    func loadSelection() -> TerminalThemeSelection {
        TerminalThemeSelection(
            darkThemeName: defaults.string(forKey: keys.darkTheme) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: keys.lightTheme) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: keys.usesPerAppearanceTheme) as? Bool ?? true
        )
    }

    func saveSelection(_ selection: TerminalThemeSelection) {
        if defaults.string(forKey: keys.darkTheme) != selection.darkThemeName {
            defaults.set(selection.darkThemeName, forKey: keys.darkTheme)
        }
        if defaults.string(forKey: keys.lightTheme) != selection.lightThemeName {
            defaults.set(selection.lightThemeName, forKey: keys.lightTheme)
        }
        if defaults.object(forKey: keys.usesPerAppearanceTheme) as? Bool != selection.usePerAppearanceTheme {
            defaults.set(selection.usePerAppearanceTheme, forKey: keys.usesPerAppearanceTheme)
        }
    }

    func loadPreferenceUpdatedAt() -> Date {
        let value = defaults.double(forKey: keys.preferenceUpdatedAt)
        guard value > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: value)
    }

    func savePreferenceUpdatedAt(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: keys.preferenceUpdatedAt)
    }

    func cacheActiveBackgroundHex(_ hex: String) {
        guard defaults.string(forKey: keys.activeBackgroundCache) != hex else { return }
        defaults.set(hex, forKey: keys.activeBackgroundCache)
    }
}
