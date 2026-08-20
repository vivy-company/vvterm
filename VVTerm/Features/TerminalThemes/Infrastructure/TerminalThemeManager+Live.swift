import Foundation

@MainActor
private final class UserDefaultsTerminalThemePreferenceChangeSource: TerminalThemePreferenceChangeSource {
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    func observeChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                observer()
            }
        }
    }

    func removeObserver(_ observer: NSObjectProtocol) {
        notificationCenter.removeObserver(observer)
    }
}

extension CloudKitSyncCoordinator: TerminalThemeMutationQueue {
    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) throws {
        try enqueue(.terminalThemeUpsert(theme))
    }

    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) throws {
        try enqueue(.terminalThemePreferenceUpsert(preference))
    }
}
extension CloudKitSyncLifecycleDriver: TerminalThemeSyncLifecycle {}

extension TerminalThemeManagerDependencies {
    static func live(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter,
        cloud: any TerminalThemeCloudClient,
        mutationQueue: any TerminalThemeMutationQueue,
        syncLifecycle: any TerminalThemeSyncLifecycle,
        themeFiles: any TerminalThemeFileSynchronizing,
        builtInThemeCatalog: any BuiltInTerminalThemeCatalog,
        paletteResolver: any TerminalThemePaletteResolving,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date
    ) -> Self {
        return TerminalThemeManagerDependencies(
            persistence: UserDefaultsTerminalThemePersistence(
                defaults: defaults,
                keys: .live
            ),
            cloud: cloud,
            mutationQueue: mutationQueue,
            syncLifecycle: syncLifecycle,
            preferenceChanges: UserDefaultsTerminalThemePreferenceChangeSource(
                defaults: defaults,
                notificationCenter: notificationCenter
            ),
            themeFiles: themeFiles,
            builtInThemeCatalog: builtInThemeCatalog,
            paletteResolver: paletteResolver,
            isSyncEnabled: isSyncEnabled,
            now: now,
            waitForPreferenceSyncDebounce: {
                try await Task.sleep(nanoseconds: 600_000_000)
            },
            startsSynchronization: true
        )
    }
}
