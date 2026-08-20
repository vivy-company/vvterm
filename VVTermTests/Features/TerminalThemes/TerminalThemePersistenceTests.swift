import Combine
import XCTest
@testable import VVTerm

@MainActor
private final class TerminalThemeCloudStub: TerminalThemeCloudClient {
    var themes: [TerminalTheme] = []
    var preference: TerminalThemePreference?
    private(set) var themeFetchCount = 0
    var onThemeFetch: (() -> Void)?
    var themesHandler: (() async throws -> [TerminalTheme])?

    func fetchTerminalThemes() async throws -> [TerminalTheme] {
        themeFetchCount += 1
        onThemeFetch?()
        if let themesHandler {
            return try await themesHandler()
        }
        return themes
    }

    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? {
        preference
    }
}

@MainActor
private final class TerminalThemeMutationQueueSpy: TerminalThemeMutationQueue {
    private(set) var enqueuedThemes: [TerminalTheme] = []
    private(set) var enqueuedPreferences: [TerminalThemePreference] = []
    private(set) var drainCount = 0
    var onPreferenceEnqueue: (() -> Void)?
    var onDrain: (() -> Void)?
    var enqueueError: Error?

    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) throws {
        if let enqueueError { throw enqueueError }
        enqueuedThemes.append(theme)
    }

    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) throws {
        onPreferenceEnqueue?()
        if let enqueueError { throw enqueueError }
        enqueuedPreferences.append(preference)
    }

    func drainPendingMutations() async {
        drainCount += 1
        onDrain?()
    }

    func reset() {
        enqueuedThemes.removeAll()
        enqueuedPreferences.removeAll()
        drainCount = 0
        onPreferenceEnqueue = nil
        onDrain = nil
        enqueueError = nil
    }
}

private enum TerminalThemeMutationQueueTestError: Error {
    case rejected
}

@MainActor
private final class TerminalThemeSyncLifecycleStub: TerminalThemeSyncLifecycle {
    private var observers: [UUID: (CloudKitSyncLifecycleEvent) -> Void] = [:]
    private(set) var removedObserverIDs: [UUID] = []
    var onRemove: (() -> Void)?

    func observe(
        _ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        removedObserverIDs.append(id)
        onRemove?()
    }

    func publish(_ event: CloudKitSyncLifecycleEvent) {
        for observer in observers.values {
            observer(event)
        }
    }
}

@MainActor
private final class TerminalThemePreferenceChangeSourceStub: TerminalThemePreferenceChangeSource {
    private final class ObserverToken: NSObject {}

    private var observers: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]
    private(set) var removeCount = 0
    var onRemove: (() -> Void)?

    func observeChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        let token = ObserverToken()
        observers[ObjectIdentifier(token)] = observer
        return token
    }

    func removeObserver(_ observer: NSObjectProtocol) {
        guard let object = observer as? AnyObject else { return }
        observers.removeValue(forKey: ObjectIdentifier(object))
        removeCount += 1
        onRemove?()
    }

    func publish() {
        for observer in observers.values {
            observer()
        }
    }
}

@MainActor
private final class TerminalThemePersistenceSpy: TerminalThemePersistence {
    var themes: [TerminalTheme]
    var selection: TerminalThemeSelection
    var preferenceUpdatedAt: Date
    private(set) var savedThemeSnapshots: [[TerminalTheme]] = []
    private(set) var savedSelections: [TerminalThemeSelection] = []
    private(set) var cachedBackgroundHexes: [String] = []

    init(
        themes: [TerminalTheme] = [],
        selection: TerminalThemeSelection = TerminalThemeSelection(
            darkThemeName: "Aizen Dark",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true
        ),
        preferenceUpdatedAt: Date = .distantPast
    ) {
        self.themes = themes
        self.selection = selection
        self.preferenceUpdatedAt = preferenceUpdatedAt
    }

    func loadCustomThemes() throws -> [TerminalTheme] {
        themes
    }

    func saveCustomThemes(_ themes: [TerminalTheme]) throws {
        self.themes = themes
        savedThemeSnapshots.append(themes)
    }

    func loadSelection() -> TerminalThemeSelection {
        selection
    }

    func saveSelection(_ selection: TerminalThemeSelection) {
        self.selection = selection
        savedSelections.append(selection)
    }

    func loadPreferenceUpdatedAt() -> Date {
        preferenceUpdatedAt
    }

    func savePreferenceUpdatedAt(_ date: Date) {
        preferenceUpdatedAt = date
    }

    func cacheActiveBackgroundHex(_ hex: String) {
        cachedBackgroundHexes.append(hex)
    }
}

@MainActor
private final class TerminalThemeFilesSpy: TerminalThemeFileSynchronizing {
    private(set) var synchronizedThemes: [[TerminalTheme]] = []

    func synchronize(_ themes: [TerminalTheme]) throws {
        synchronizedThemes.append(themes)
    }
}

@MainActor
private struct BuiltInTerminalThemeCatalogStub: BuiltInTerminalThemeCatalog {
    let names: [String]

    func themeNames() -> [String] {
        names
    }
}

@MainActor
private final class TerminalThemePaletteResolverSpy: TerminalThemePaletteResolving {
    let namedPalette: TerminalThemePalette
    let contentPalette: TerminalThemePalette
    private(set) var resolvedNames: [String] = []
    private(set) var resolvedContents: [String] = []
    private(set) var cacheInvalidationCount = 0

    init(
        namedPalette: TerminalThemePalette = .fallback,
        contentPalette: TerminalThemePalette = .fallback
    ) {
        self.namedPalette = namedPalette
        self.contentPalette = contentPalette
    }

    func palette(forThemeNamed name: String) -> TerminalThemePalette {
        resolvedNames.append(name)
        return namedPalette
    }

    func palette(forThemeContent content: String) -> TerminalThemePalette {
        resolvedContents.append(content)
        return contentPalette
    }

    func invalidateCache() {
        cacheInvalidationCount += 1
    }
}

@MainActor
private final class TerminalThemeDebounceGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var onWait: (() -> Void)?
    var onCancel: (() -> Void)?

    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                onWait?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.onCancel?()
            }
        }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class TerminalThemeCloudGate {
    private var continuation: CheckedContinuation<[TerminalTheme], Never>?
    var onWait: (() -> Void)?
    var onCancel: (() -> Void)?

    func wait() async throws -> [TerminalTheme] {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                onWait?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.onCancel?()
            }
        }
    }

    func resolve(_ themes: [TerminalTheme]) {
        continuation?.resume(returning: themes)
        continuation = nil
    }
}

@MainActor
final class TerminalThemePersistenceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let persistenceKeys = TerminalThemeUserDefaultsKeys(
        customThemes: "test.terminal-themes",
        darkTheme: "test.terminal-theme.dark",
        lightTheme: "test.terminal-theme.light",
        usesPerAppearanceTheme: "test.terminal-theme.per-appearance",
        preferenceUpdatedAt: "test.terminal-theme.updated-at",
        activeBackgroundCache: "test.terminal-theme.background"
    )

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermThemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testLiveDependenciesRouteInjectedOwnersAndFacts() throws {
        let suiteName = "TerminalThemeLiveDependenciesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let cloud = TerminalThemeCloudStub()
        let queue = TerminalThemeMutationQueueSpy()
        let lifecycle = TerminalThemeSyncLifecycleStub()
        let themeFiles = TerminalThemeFilesSpy()
        let catalog = BuiltInTerminalThemeCatalogStub(names: ["Injected Theme"])
        let paletteResolver = TerminalThemePaletteResolverSpy()
        let now = Date(timeIntervalSince1970: 123)
        var syncEnabled = true
        let dependencies = TerminalThemeManagerDependencies.live(
            defaults: defaults,
            notificationCenter: notificationCenter,
            cloud: cloud,
            mutationQueue: queue,
            syncLifecycle: lifecycle,
            themeFiles: themeFiles,
            builtInThemeCatalog: catalog,
            paletteResolver: paletteResolver,
            isSyncEnabled: { syncEnabled },
            now: { now }
        )

        XCTAssertTrue(dependencies.cloud === cloud)
        XCTAssertTrue(dependencies.mutationQueue === queue)
        XCTAssertTrue(dependencies.syncLifecycle === lifecycle)
        XCTAssertTrue((dependencies.themeFiles as? TerminalThemeFilesSpy) === themeFiles)
        XCTAssertTrue(
            (dependencies.paletteResolver as? TerminalThemePaletteResolverSpy)
                === paletteResolver
        )
        XCTAssertEqual(dependencies.builtInThemeCatalog.themeNames(), ["Injected Theme"])
        XCTAssertTrue(dependencies.isSyncEnabled())
        syncEnabled = false
        XCTAssertFalse(dependencies.isSyncEnabled())
        XCTAssertEqual(dependencies.now(), now)
        XCTAssertTrue(dependencies.startsSynchronization)

        let selection = TerminalThemeSelection(
            darkThemeName: "Injected Dark",
            lightThemeName: "Injected Light",
            usePerAppearanceTheme: true
        )
        dependencies.persistence.saveSelection(selection)
        XCTAssertEqual(
            defaults.string(forKey: TerminalThemeUserDefaultsKeys.live.darkTheme),
            selection.darkThemeName
        )
        XCTAssertEqual(
            defaults.string(forKey: TerminalThemeUserDefaultsKeys.live.lightTheme),
            selection.lightThemeName
        )

        var notificationCount = 0
        let observer = dependencies.preferenceChanges.observeChanges {
            notificationCount += 1
        }
        notificationCenter.post(
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
        XCTAssertEqual(notificationCount, 1)
        dependencies.preferenceChanges.removeObserver(observer)
    }

    func testInvalidThemeSurvivesLoadingAndDoesNotDeleteItsFileOrSelection() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = "background = #000000\nforeground = #ffffff\ncommand = whoami\n"
        let theme = TerminalTheme(name: "Legacy Theme", content: original)
        defaults.set(
            try JSONEncoder().encode([theme]),
            forKey: persistenceKeys.customThemes
        )
        defaults.set(theme.name, forKey: persistenceKeys.darkTheme)

        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let fileURL = try XCTUnwrap(store.fileURL(for: theme.name))
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = makeManager(defaults: defaults, themeFiles: store)

        XCTAssertEqual(manager.customThemes, [theme])
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), original)
        XCTAssertEqual(
            defaults.string(forKey: persistenceKeys.darkTheme),
            theme.name
        )
        XCTAssertEqual(
            manager.applicationThemeName(preferred: theme.name, fallback: "Aizen Dark"),
            "Aizen Dark"
        )
        XCTAssertEqual(
            manager.appearanceSnapshot(for: .dark).activeTheme.name,
            "Aizen Dark"
        )
    }

    func testMalformedPersistedThemesLoadAsEmptyWithoutReplacingTheStoredData() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformedData = Data("not-json".utf8)
        defaults.set(malformedData, forKey: persistenceKeys.customThemes)

        let manager = makeManager(defaults: defaults)

        XCTAssertTrue(manager.customThemes.isEmpty)
        XCTAssertEqual(defaults.data(forKey: persistenceKeys.customThemes), malformedData)
    }

    func testValidThemeWriteDoesNotDeleteUnrelatedThemeFiles() throws {
        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let unrelatedURL = temporaryDirectory.appendingPathComponent("Existing Legacy Theme")
        let original = "legacy content"
        try original.write(to: unrelatedURL, atomically: true, encoding: .utf8)

        let validTheme = TerminalTheme(
            name: "Valid Theme",
            content: "background = #000000\nforeground = #ffffff\n"
        )
        try store.synchronize([validTheme])

        XCTAssertEqual(try String(contentsOf: unrelatedURL, encoding: .utf8), original)
        let validURL = try XCTUnwrap(store.fileURL(for: validTheme.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))
    }

    func testFailedValidationDoesNotReplaceExistingThemeFile() throws {
        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let theme = TerminalTheme(
            name: "Needs Repair",
            content: "background = #000000\nforeground = #ffffff\ncommand = whoami\n"
        )
        let fileURL = try XCTUnwrap(store.fileURL(for: theme.name))
        let existing = "background = #112233\nforeground = #ddeeff\n"
        try existing.write(to: fileURL, atomically: true, encoding: .utf8)

        try store.synchronize([theme])

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), existing)
    }

    func testInvalidRemoteThemeDoesNotReplaceValidLocalTheme() {
        let id = UUID()
        let local = TerminalTheme(
            id: id,
            name: "Safe Theme",
            content: "background = #000000\nforeground = #ffffff\n",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let invalidRemote = TerminalTheme(
            id: id,
            name: "Safe Theme",
            content: "background = #000000\nforeground = #ffffff\ncommand = whoami\n",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(TerminalThemeMergePolicy.merge(local: [local], remote: [invalidRemote]), [local])
    }

    func testExplicitDeletionRemovesThemeFile() throws {
        let store = TerminalThemeFileStore(directoryURL: temporaryDirectory)
        var theme = TerminalTheme(
            name: "Delete Me",
            content: "background = #000000\nforeground = #ffffff\n"
        )
        try store.synchronize([theme])
        let fileURL = try XCTUnwrap(store.fileURL(for: theme.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        theme.deletedAt = Date()
        try store.synchronize([theme])

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAppearanceSnapshotResolvesBothThemesFromOnePreferenceSnapshot() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let darkTheme = TerminalTheme(
            name: "Test Dark",
            content: "background = #102030\nforeground = #A0B0C0\ncursor-color = #D0E0F0\n"
        )
        let lightTheme = TerminalTheme(
            name: "Test Light",
            content: "background = #F1F2F3\nforeground = #112233\ncursor-text = #445566\n"
        )
        defaults.set(
            try JSONEncoder().encode([darkTheme, lightTheme]),
            forKey: persistenceKeys.customThemes
        )
        defaults.set(darkTheme.name, forKey: persistenceKeys.darkTheme)
        defaults.set(lightTheme.name, forKey: persistenceKeys.lightTheme)
        defaults.set(true, forKey: persistenceKeys.usesPerAppearanceTheme)

        let manager = makeManager(defaults: defaults)
        let snapshot = manager.appearanceSnapshot(for: .light)

        XCTAssertEqual(snapshot.activeTheme.name, lightTheme.name)
        XCTAssertEqual(snapshot.lightTheme.palette.backgroundHex, "#F1F2F3")
        XCTAssertEqual(snapshot.lightTheme.palette.foregroundHex, "#112233")
        XCTAssertEqual(snapshot.lightTheme.palette.cursorHex, "#112233")
        XCTAssertEqual(snapshot.lightTheme.palette.cursorTextHex, "#445566")
        XCTAssertEqual(snapshot.darkTheme.palette.backgroundHex, "#102030")
        XCTAssertEqual(snapshot.darkTheme.palette.foregroundHex, "#A0B0C0")
        XCTAssertEqual(snapshot.darkTheme.palette.cursorHex, "#D0E0F0")
        XCTAssertEqual(snapshot.darkTheme.palette.cursorTextHex, "#102030")
    }

    func testAppearanceActivationIsOrderedAndOwnsLegacyBackgroundCache() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let darkTheme = TerminalTheme(
            name: "Ordered Dark",
            content: "background = #010203\nforeground = #FFFFFF\n"
        )
        let lightTheme = TerminalTheme(
            name: "Ordered Light",
            content: "background = #FDFCFB\nforeground = #000000\n"
        )
        defaults.set(
            try JSONEncoder().encode([darkTheme, lightTheme]),
            forKey: persistenceKeys.customThemes
        )
        defaults.set(darkTheme.name, forKey: persistenceKeys.darkTheme)
        defaults.set(lightTheme.name, forKey: persistenceKeys.lightTheme)
        defaults.set(true, forKey: persistenceKeys.usesPerAppearanceTheme)

        let manager = makeManager(defaults: defaults)

        let lightSnapshot = manager.activateAppearance(.light)
        XCTAssertEqual(manager.activeAppearanceSnapshot, lightSnapshot)
        XCTAssertEqual(defaults.string(forKey: persistenceKeys.activeBackgroundCache), "#FDFCFB")

        let darkSnapshot = manager.activateAppearance(.dark)
        XCTAssertEqual(manager.activeAppearanceSnapshot, darkSnapshot)
        XCTAssertEqual(defaults.string(forKey: persistenceKeys.activeBackgroundCache), "#010203")
    }

    func testInjectedThemePortsOwnFilesCatalogAndCustomPaletteResolution() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let theme = TerminalTheme(
            name: "Port Theme",
            content: "background = #102030\nforeground = #A0B0C0\n"
        )
        defaults.set(try JSONEncoder().encode([theme]), forKey: persistenceKeys.customThemes)
        defaults.set(theme.name, forKey: persistenceKeys.darkTheme)
        defaults.set(false, forKey: persistenceKeys.usesPerAppearanceTheme)
        let themeFiles = TerminalThemeFilesSpy()
        let catalog = BuiltInTerminalThemeCatalogStub(
            names: ["Aizen Dark", "Aizen Light", "Reserved"]
        )
        let customPalette = TerminalThemePalette(
            backgroundHex: "#010203",
            foregroundHex: "#040506",
            cursorHex: "#070809",
            cursorTextHex: "#0A0B0C"
        )
        let paletteResolver = TerminalThemePaletteResolverSpy(
            contentPalette: customPalette
        )

        let manager = makeManager(
            defaults: defaults,
            themeFiles: themeFiles,
            builtInThemeCatalog: catalog,
            paletteResolver: paletteResolver
        )

        XCTAssertEqual(themeFiles.synchronizedThemes, [[theme]])
        XCTAssertEqual(paletteResolver.cacheInvalidationCount, 1)
        XCTAssertEqual(paletteResolver.resolvedContents, [theme.content])
        XCTAssertTrue(paletteResolver.resolvedNames.isEmpty)
        XCTAssertEqual(manager.activeAppearanceSnapshot.darkTheme.palette, customPalette)
        XCTAssertEqual(manager.suggestThemeName(from: "Reserved"), "Reserved 2")
    }

    func testInjectedPaletteResolverHandlesBuiltInTheme() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Catalog Theme", forKey: persistenceKeys.darkTheme)
        defaults.set(false, forKey: persistenceKeys.usesPerAppearanceTheme)
        let namedPalette = TerminalThemePalette(
            backgroundHex: "#111111",
            foregroundHex: "#222222",
            cursorHex: "#333333",
            cursorTextHex: "#444444"
        )
        let paletteResolver = TerminalThemePaletteResolverSpy(
            namedPalette: namedPalette
        )

        let manager = makeManager(
            defaults: defaults,
            builtInThemeCatalog: BuiltInTerminalThemeCatalogStub(
                names: ["Aizen Dark", "Aizen Light", "Catalog Theme"]
            ),
            paletteResolver: paletteResolver
        )

        XCTAssertEqual(paletteResolver.resolvedNames, ["Catalog Theme"])
        XCTAssertTrue(paletteResolver.resolvedContents.isEmpty)
        XCTAssertEqual(manager.activeAppearanceSnapshot.darkTheme.palette, namedPalette)
    }

    func testInjectedClockAndPersistenceAdapterOwnThemeMutation() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1234)
        let manager = makeManager(defaults: defaults, now: { now })

        let theme = try manager.createCustomTheme(
            name: "Clocked",
            content: "background = #010203\nforeground = #FFFFFF\n"
        )

        XCTAssertEqual(theme.updatedAt, now)
        XCTAssertNotNil(defaults.data(forKey: persistenceKeys.customThemes))
    }

    func testInjectedPersistencePortOwnsThemeLoadAndSave() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let existingTheme = TerminalTheme(
            name: "Existing",
            content: "background = #010203\nforeground = #FFFFFF\n"
        )
        let persistence = TerminalThemePersistenceSpy(themes: [existingTheme])
        let manager = makeManager(
            defaults: defaults,
            persistence: persistence,
            themeFiles: TerminalThemeFilesSpy(),
            paletteResolver: TerminalThemePaletteResolverSpy()
        )

        XCTAssertEqual(manager.customThemes, [existingTheme])

        let createdTheme = try manager.createCustomTheme(
            name: "Created",
            content: "background = #112233\nforeground = #FFFFFF\n"
        )

        XCTAssertEqual(
            persistence.savedThemeSnapshots.last,
            [existingTheme, createdTheme]
        )
        XCTAssertEqual(persistence.cachedBackgroundHexes.last, "#101418")
    }

    func testRenamedThemeMigratesBothSelectionsThroughPersistencePort() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let existingTheme = TerminalTheme(
            id: themeID,
            name: "Old Name",
            content: "background = #010203\nforeground = #FFFFFF\n"
        )
        let persistence = TerminalThemePersistenceSpy(
            themes: [existingTheme],
            selection: TerminalThemeSelection(
                darkThemeName: existingTheme.name,
                lightThemeName: existingTheme.name,
                usePerAppearanceTheme: true
            )
        )
        let manager = makeManager(
            defaults: defaults,
            persistence: persistence,
            themeFiles: TerminalThemeFilesSpy()
        )

        _ = try manager.updateCustomTheme(
            id: themeID,
            name: "New Name",
            content: existingTheme.content
        )

        XCTAssertEqual(
            persistence.selection,
            TerminalThemeSelection(
                darkThemeName: "New Name",
                lightThemeName: "New Name",
                usePerAppearanceTheme: true
            )
        )
        XCTAssertEqual(manager.themeSelection, persistence.selection)
    }

    func testUISelectionUpdatePersistsPublishesAndActivatesExactlyOnce() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = TerminalThemePersistenceSpy()
        let manager = makeManager(defaults: defaults, persistence: persistence)
        var publishedSelections: [TerminalThemeSelection] = []
        let observation = manager.$themeSelection.dropFirst().sink {
            publishedSelections.append($0)
        }
        defer { observation.cancel() }
        let initialSelectionWriteCount = persistence.savedSelections.count
        let initialCacheWriteCount = persistence.cachedBackgroundHexes.count
        let expected = TerminalThemeSelection(
            darkThemeName: "Aizen Light",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true
        )

        manager.selectTheme(named: "Aizen Light", for: .both)

        XCTAssertEqual(manager.themeSelection, expected)
        XCTAssertEqual(persistence.selection, expected)
        XCTAssertEqual(
            persistence.savedSelections.count,
            initialSelectionWriteCount + 1
        )
        XCTAssertEqual(publishedSelections, [expected])
        XCTAssertEqual(
            persistence.cachedBackgroundHexes.count,
            initialCacheWriteCount + 1
        )
    }

    func testSelectionUpdatesAreIdempotent() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = TerminalThemePersistenceSpy()
        let manager = makeManager(defaults: defaults, persistence: persistence)
        var publishedSelectionCount = 0
        let observation = manager.$themeSelection.dropFirst().sink { _ in
            publishedSelectionCount += 1
        }
        defer { observation.cancel() }
        let initialSelectionWriteCount = persistence.savedSelections.count
        let initialCacheWriteCount = persistence.cachedBackgroundHexes.count

        manager.selectTheme(named: "Aizen Dark", for: .dark)
        manager.selectTheme(named: "Aizen Light", for: .light)
        manager.setUsesPerAppearanceTheme(true)

        XCTAssertEqual(persistence.savedSelections.count, initialSelectionWriteCount)
        XCTAssertEqual(publishedSelectionCount, 0)
        XCTAssertEqual(
            persistence.cachedBackgroundHexes.count,
            initialCacheWriteCount
        )
    }

    func testInvalidUISelectionIsNormalizedByTheManager() throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = TerminalThemePersistenceSpy(
            selection: TerminalThemeSelection(
                darkThemeName: "Aizen Light",
                lightThemeName: "Aizen Dark",
                usePerAppearanceTheme: true
            )
        )
        let manager = makeManager(defaults: defaults, persistence: persistence)
        let initialSelectionWriteCount = persistence.savedSelections.count
        let expected = TerminalThemeSelection(
            darkThemeName: "Aizen Dark",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true
        )

        manager.selectTheme(named: "../Missing Theme", for: .both)

        XCTAssertEqual(manager.themeSelection, expected)
        XCTAssertEqual(persistence.selection, expected)
        XCTAssertEqual(
            persistence.savedSelections.count,
            initialSelectionWriteCount + 1
        )
    }

    func testForegroundAndSyncEnabledUseInjectedStateAndFeatureMergePolicy() async throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeID = UUID()
        let local = TerminalTheme(
            id: themeID,
            name: "Local",
            content: "background = #000000\nforeground = #ffffff\n",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        defaults.set(try JSONEncoder().encode([local]), forKey: persistenceKeys.customThemes)
        let remote = TerminalTheme(
            id: themeID,
            name: "Remote",
            content: "background = #112233\nforeground = #ffffff\n",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let cloud = TerminalThemeCloudStub()
        cloud.themes = [remote]
        cloud.preference = TerminalThemePreference(
            darkThemeName: "Aizen Dark",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true,
            updatedAt: .distantPast
        )
        let queue = TerminalThemeMutationQueueSpy()
        let lifecycle = TerminalThemeSyncLifecycleStub()
        var syncEnabled = false
        let manager = makeManager(
            defaults: defaults,
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { syncEnabled },
            startsSynchronization: true
        )
        lifecycle.publish(.foreground)
        XCTAssertEqual(cloud.themeFetchCount, 0)
        XCTAssertEqual(manager.customThemes, [local])

        let synced = expectation(description: "enabled theme sync")
        let enabledDrained = expectation(description: "enabled theme drain")
        cloud.onThemeFetch = { synced.fulfill() }
        queue.onDrain = { enabledDrained.fulfill() }
        syncEnabled = true
        lifecycle.publish(.syncEnabled)
        await fulfillment(of: [synced, enabledDrained], timeout: 1)

        XCTAssertEqual(manager.customThemes, [remote])
        XCTAssertEqual(queue.drainCount, 1)
    }

    func testPreferenceDebounceCoalescesAndSyncDisabledCancelsPendingWork() async throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = TerminalThemeCloudStub()
        cloud.preference = TerminalThemePreference(
            darkThemeName: "Aizen Dark",
            lightThemeName: "Aizen Light",
            usePerAppearanceTheme: true,
            updatedAt: .distantPast
        )
        let queue = TerminalThemeMutationQueueSpy()
        let lifecycle = TerminalThemeSyncLifecycleStub()
        let preferenceChanges = TerminalThemePreferenceChangeSourceStub()
        let debounce = TerminalThemeDebounceGate()
        let startupDrained = expectation(description: "startup drain")
        queue.onDrain = { startupDrained.fulfill() }
        let manager = makeManager(
            defaults: defaults,
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            preferenceChanges: preferenceChanges,
            isSyncEnabled: { true },
            waitForPreferenceSyncDebounce: debounce.wait,
            startsSynchronization: true
        )
        _ = manager
        await fulfillment(of: [startupDrained], timeout: 1)
        queue.reset()

        let firstWait = expectation(description: "first preference debounce")
        debounce.onWait = { firstWait.fulfill() }
        defaults.set("Aizen Light", forKey: persistenceKeys.darkTheme)
        preferenceChanges.publish()
        await fulfillment(of: [firstWait], timeout: 1)

        let secondWait = expectation(description: "replacement preference debounce")
        debounce.onWait = { secondWait.fulfill() }
        defaults.set("Aizen Dark", forKey: persistenceKeys.darkTheme)
        preferenceChanges.publish()
        await fulfillment(of: [secondWait], timeout: 1)
        let enqueued = expectation(description: "coalesced preference enqueue")
        queue.onPreferenceEnqueue = { enqueued.fulfill() }
        debounce.releaseAll()
        await fulfillment(of: [enqueued], timeout: 1)
        XCTAssertEqual(queue.enqueuedPreferences.count, 1)

        let thirdWait = expectation(description: "pending disabled preference")
        let thirdCancelled = expectation(description: "disabled preference cancellation observed")
        debounce.onWait = { thirdWait.fulfill() }
        debounce.onCancel = { thirdCancelled.fulfill() }
        defaults.set("Aizen Light", forKey: persistenceKeys.darkTheme)
        preferenceChanges.publish()
        await fulfillment(of: [thirdWait], timeout: 1)
        lifecycle.publish(.syncDisabled)
        await fulfillment(of: [thirdCancelled], timeout: 1)
        debounce.releaseAll()
        await Task.yield()
        XCTAssertEqual(queue.enqueuedPreferences.count, 1)
    }

    func testPreferenceQueueFailureDoesNotStartDrain() async throws {
        let suiteName = "TerminalThemePersistenceTests.queueFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = TerminalThemeMutationQueueSpy()
        let preferenceChanges = TerminalThemePreferenceChangeSourceStub()
        let startupDrained = expectation(description: "startup drain")
        queue.onDrain = { startupDrained.fulfill() }
        let manager = makeManager(
            defaults: defaults,
            queue: queue,
            preferenceChanges: preferenceChanges,
            isSyncEnabled: { true },
            waitForPreferenceSyncDebounce: {},
            startsSynchronization: true
        )
        await fulfillment(of: [startupDrained], timeout: 1)
        queue.reset()

        queue.enqueueError = TerminalThemeMutationQueueTestError.rejected
        let attempted = expectation(description: "preference enqueue attempted")
        queue.onPreferenceEnqueue = { attempted.fulfill() }

        defaults.set("Aizen Light", forKey: persistenceKeys.darkTheme)
        preferenceChanges.publish()
        await fulfillment(of: [attempted], timeout: 1)
        await Task.yield()

        _ = manager
        XCTAssertTrue(queue.enqueuedPreferences.isEmpty)
        XCTAssertEqual(queue.drainCount, 0)
    }

    func testBlockedStartupDoesNotRetainOwnerAndObservesCancellation() async throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = TerminalThemeCloudStub()
        let queue = TerminalThemeMutationQueueSpy()
        let gate = TerminalThemeCloudGate()
        let started = expectation(description: "blocked startup began")
        let cancelled = expectation(description: "blocked startup cancelled")
        gate.onWait = { started.fulfill() }
        gate.onCancel = { cancelled.fulfill() }
        cloud.themesHandler = gate.wait
        var manager: TerminalThemeManager? = makeManager(
            defaults: defaults,
            cloud: cloud,
            queue: queue,
            isSyncEnabled: { true },
            startsSynchronization: true
        )
        weak var releasedManager: TerminalThemeManager?
        releasedManager = manager

        await fulfillment(of: [started], timeout: 1)
        manager = nil
        await fulfillment(of: [cancelled], timeout: 1)

        XCTAssertNil(releasedManager)
        XCTAssertEqual(queue.drainCount, 0)
        gate.resolve([])
    }

    func testBlockedDebounceDoesNotRetainOwnerAndObservesCancellation() async throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = TerminalThemeMutationQueueSpy()
        let preferenceChanges = TerminalThemePreferenceChangeSourceStub()
        let debounce = TerminalThemeDebounceGate()
        let startupDrained = expectation(description: "startup drain")
        queue.onDrain = { startupDrained.fulfill() }
        var manager: TerminalThemeManager? = makeManager(
            defaults: defaults,
            queue: queue,
            preferenceChanges: preferenceChanges,
            isSyncEnabled: { true },
            waitForPreferenceSyncDebounce: debounce.wait,
            startsSynchronization: true
        )
        weak var releasedManager: TerminalThemeManager?
        releasedManager = manager
        await fulfillment(of: [startupDrained], timeout: 1)
        queue.reset()
        let started = expectation(description: "blocked debounce began")
        let cancelled = expectation(description: "blocked debounce cancelled")
        debounce.onWait = { started.fulfill() }
        debounce.onCancel = { cancelled.fulfill() }

        defaults.set("Aizen Light", forKey: persistenceKeys.darkTheme)
        preferenceChanges.publish()
        await fulfillment(of: [started], timeout: 1)
        manager = nil
        await fulfillment(of: [cancelled], timeout: 1)

        XCTAssertNil(releasedManager)
        debounce.releaseAll()
        await Task.yield()
        XCTAssertTrue(queue.enqueuedPreferences.isEmpty)
    }

    func testSyncDisabledRejectsBlockedStartupCompletionAndSkipsDrain() async throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = TerminalThemeCloudStub()
        let queue = TerminalThemeMutationQueueSpy()
        let lifecycle = TerminalThemeSyncLifecycleStub()
        let gate = TerminalThemeCloudGate()
        let started = expectation(description: "blocked startup began")
        let cancelled = expectation(description: "blocked startup cancelled")
        gate.onWait = { started.fulfill() }
        gate.onCancel = { cancelled.fulfill() }
        cloud.themesHandler = gate.wait
        var syncEnabled = true
        let manager = makeManager(
            defaults: defaults,
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { syncEnabled },
            startsSynchronization: true
        )
        let remote = TerminalTheme(
            name: "Late Remote",
            content: "background = #112233\nforeground = #ffffff\n",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        await fulfillment(of: [started], timeout: 1)
        syncEnabled = false
        lifecycle.publish(.syncDisabled)
        await fulfillment(of: [cancelled], timeout: 1)
        gate.resolve([remote])
        await Task.yield()

        XCTAssertTrue(manager.customThemes.isEmpty)
        XCTAssertEqual(queue.drainCount, 0)
    }

    func testDeinitRemovesInjectedLifecycleObserver() async throws {
        let suiteName = "TerminalThemePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lifecycle = TerminalThemeSyncLifecycleStub()
        let preferenceChanges = TerminalThemePreferenceChangeSourceStub()
        let removed = expectation(description: "theme lifecycle observer removed")
        let preferenceRemoved = expectation(description: "theme preference observer removed")
        lifecycle.onRemove = { removed.fulfill() }
        preferenceChanges.onRemove = { preferenceRemoved.fulfill() }
        var manager: TerminalThemeManager? = makeManager(
            defaults: defaults,
            lifecycle: lifecycle,
            preferenceChanges: preferenceChanges,
            startsSynchronization: true
        )
        weak var releasedManager: TerminalThemeManager?
        releasedManager = manager

        manager = nil
        await fulfillment(of: [removed, preferenceRemoved], timeout: 1)

        XCTAssertNil(releasedManager)
        XCTAssertEqual(lifecycle.removedObserverIDs.count, 1)
        XCTAssertEqual(preferenceChanges.removeCount, 1)
    }

    private func makeManager(
        defaults: UserDefaults,
        persistence: (any TerminalThemePersistence)? = nil,
        cloud: TerminalThemeCloudStub? = nil,
        queue: TerminalThemeMutationQueueSpy? = nil,
        lifecycle: TerminalThemeSyncLifecycleStub? = nil,
        preferenceChanges: TerminalThemePreferenceChangeSourceStub? = nil,
        themeFiles: (any TerminalThemeFileSynchronizing)? = nil,
        builtInThemeCatalog: (any BuiltInTerminalThemeCatalog)? = nil,
        paletteResolver: (any TerminalThemePaletteResolving)? = nil,
        isSyncEnabled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init,
        waitForPreferenceSyncDebounce: @escaping () async throws -> Void = {},
        startsSynchronization: Bool = false
    ) -> TerminalThemeManager {
        let cloud = cloud ?? TerminalThemeCloudStub()
        let queue = queue ?? TerminalThemeMutationQueueSpy()
        let lifecycle = lifecycle ?? TerminalThemeSyncLifecycleStub()
        let preferenceChanges = preferenceChanges ?? TerminalThemePreferenceChangeSourceStub()
        let themeFiles = themeFiles ?? TerminalThemeFileStore(directoryURL: temporaryDirectory)
        let builtInThemeCatalog = builtInThemeCatalog ?? BuiltInTerminalThemeCatalogStub(
            names: ["Aizen Dark", "Aizen Light"]
        )
        let paletteResolver = paletteResolver ?? ThemeColorParserPaletteResolver()
        return TerminalThemeManager(
            dependencies: TerminalThemeManagerDependencies(
                persistence: persistence ?? UserDefaultsTerminalThemePersistence(
                    defaults: defaults,
                    keys: persistenceKeys
                ),
                cloud: cloud,
                mutationQueue: queue,
                syncLifecycle: lifecycle,
                preferenceChanges: preferenceChanges,
                themeFiles: themeFiles,
                builtInThemeCatalog: builtInThemeCatalog,
                paletteResolver: paletteResolver,
                isSyncEnabled: isSyncEnabled,
                now: now,
                waitForPreferenceSyncDebounce: waitForPreferenceSyncDebounce,
                startsSynchronization: startsSynchronization
            )
        )
    }
}
