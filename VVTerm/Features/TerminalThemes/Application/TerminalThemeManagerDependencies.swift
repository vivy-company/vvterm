import Foundation

@MainActor
protocol TerminalThemeCloudClient: AnyObject {
    func fetchTerminalThemes() async throws -> [TerminalTheme]
    func fetchTerminalThemePreference() async throws -> TerminalThemePreference?
}

@MainActor
protocol TerminalThemeCloudMutationClient: AnyObject {
    func saveTerminalTheme(_ theme: TerminalTheme) async throws
    func saveTerminalThemePreference(_ preference: TerminalThemePreference) async throws
}

@MainActor
protocol TerminalThemeMutationQueue: AnyObject {
    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) throws
    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) throws
    func drainPendingMutations() async
}

@MainActor
protocol TerminalThemeSyncLifecycle: AnyObject {
    func observe(
        _ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void
    ) -> UUID
    func removeObserver(_ id: UUID)
}

@MainActor
protocol TerminalThemePreferenceChangeSource: AnyObject {
    func observeChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol
    func removeObserver(_ observer: NSObjectProtocol)
}

@MainActor
protocol TerminalThemePersistence: AnyObject {
    func loadCustomThemes() throws -> [TerminalTheme]
    func saveCustomThemes(_ themes: [TerminalTheme]) throws
    func loadSelection() -> TerminalThemeSelection
    func saveSelection(_ selection: TerminalThemeSelection)
    func loadPreferenceUpdatedAt() -> Date
    func savePreferenceUpdatedAt(_ date: Date)
    func cacheActiveBackgroundHex(_ hex: String)
}

@MainActor
protocol TerminalThemeFileSynchronizing {
    func synchronize(_ themes: [TerminalTheme]) throws
}

@MainActor
protocol BuiltInTerminalThemeCatalog {
    func themeNames() -> [String]
}

@MainActor
protocol TerminalThemePaletteResolving {
    func palette(forThemeNamed name: String) -> TerminalThemePalette
    func palette(forThemeContent content: String) -> TerminalThemePalette
    func invalidateCache()
}

@MainActor
struct TerminalThemeManagerDependencies {
    let persistence: any TerminalThemePersistence
    let cloud: any TerminalThemeCloudClient
    let mutationQueue: any TerminalThemeMutationQueue
    let syncLifecycle: any TerminalThemeSyncLifecycle
    let preferenceChanges: any TerminalThemePreferenceChangeSource
    let themeFiles: any TerminalThemeFileSynchronizing
    let builtInThemeCatalog: any BuiltInTerminalThemeCatalog
    let paletteResolver: any TerminalThemePaletteResolving
    let isSyncEnabled: () -> Bool
    let now: () -> Date
    let waitForPreferenceSyncDebounce: () async throws -> Void
    let startsSynchronization: Bool
}
