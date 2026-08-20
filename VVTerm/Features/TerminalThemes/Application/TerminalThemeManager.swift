//
//  TerminalThemeManager.swift
//  VVTerm
//

import Foundation
import Combine
import os.log

nonisolated enum TerminalThemeSelectionTarget: CaseIterable, Hashable, Sendable {
    case dark
    case light
    case both
}

nonisolated struct TerminalThemeObserverCleanupRequest: Sendable {
    private let cleanup: @MainActor @Sendable () -> Void

    init(cleanup: @escaping @MainActor @Sendable () -> Void) {
        self.cleanup = cleanup
    }

    func perform() {
        Task { @MainActor in
            cleanup()
        }
    }
}

@MainActor
private final class TerminalThemeObserverCleanup {
    private let preferenceChanges: any TerminalThemePreferenceChangeSource
    private let syncLifecycle: any TerminalThemeSyncLifecycle
    private var preferenceObserver: NSObjectProtocol?
    private var lifecycleObserverID: UUID?

    init(
        preferenceChanges: any TerminalThemePreferenceChangeSource,
        syncLifecycle: any TerminalThemeSyncLifecycle
    ) {
        self.preferenceChanges = preferenceChanges
        self.syncLifecycle = syncLifecycle
    }

    var request: TerminalThemeObserverCleanupRequest {
        TerminalThemeObserverCleanupRequest { [self] in
            removeObservers()
        }
    }

    func registerPreferenceObserver(_ observer: NSObjectProtocol) {
        preferenceObserver = observer
    }

    func registerLifecycleObserver(_ id: UUID) {
        lifecycleObserverID = id
    }

    private func removeObservers() {
        if let preferenceObserver {
            preferenceChanges.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
        if let lifecycleObserverID {
            syncLifecycle.removeObserver(lifecycleObserverID)
            self.lifecycleObserverID = nil
        }
    }
}

@MainActor
final class TerminalThemeManager: ObservableObject {
    @Published private(set) var customThemes: [TerminalTheme] = []
    @Published private(set) var themeSelection: TerminalThemeSelection
    @Published private(set) var activeAppearanceSnapshot: TerminalAppearanceSnapshot = .fallback

    private let dependencies: TerminalThemeManagerDependencies
    private let observerCleanupRequest: TerminalThemeObserverCleanupRequest
    private let logger = Logger(subsystem: "app.vivy.vvterm", category: "TerminalThemeManager")

    private var lastKnownPreferenceSnapshot: TerminalThemeSelection
    private var isApplyingRemotePreference = false
    private var pendingPreferenceSyncTask: Task<Void, Never>?
    private var startupSyncTask: Task<Void, Never>?
    private var lifecycleSyncTask: Task<Void, Never>?

    private var persistence: any TerminalThemePersistence { dependencies.persistence }

    init(dependencies: TerminalThemeManagerDependencies) {
        self.dependencies = dependencies
        let observerCleanup = TerminalThemeObserverCleanup(
            preferenceChanges: dependencies.preferenceChanges,
            syncLifecycle: dependencies.syncLifecycle
        )
        self.observerCleanupRequest = observerCleanup.request
        let initialSelection = dependencies.persistence.loadSelection()
        self.themeSelection = initialSelection
        self.lastKnownPreferenceSnapshot = initialSelection

        loadThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        guard dependencies.startsSynchronization else { return }

        observeThemePreferenceChanges(cleanup: observerCleanup)
        observeSyncLifecycle(cleanup: observerCleanup)
        startupSyncTask = makeCloudSyncTask()
    }

    deinit {
        pendingPreferenceSyncTask?.cancel()
        startupSyncTask?.cancel()
        lifecycleSyncTask?.cancel()
        observerCleanupRequest.perform()
    }

    func refreshFromCloud() async throws {
        startupSyncTask?.cancel()
        startupSyncTask = nil
        lifecycleSyncTask?.cancel()
        lifecycleSyncTask = nil
        try await synchronizeWithCloud()
    }

    var customThemeNames: [String] {
        customThemes
            .filter { !$0.isDeleted && $0.canApply }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var builtInThemeNames: [String] {
        dependencies.builtInThemeCatalog.themeNames()
    }

    func applicationThemeName(preferred: String, fallback: String) -> String {
        guard let customTheme = customThemes.first(where: {
            !$0.isDeleted && $0.name == preferred
        }) else {
            return preferred
        }
        return customTheme.canApply ? preferred : fallback
    }

    func selectTheme(
        named themeName: String,
        for target: TerminalThemeSelectionTarget
    ) {
        let current = themeSelection
        let requested: TerminalThemeSelection
        switch target {
        case .dark:
            requested = TerminalThemeSelection(
                darkThemeName: themeName,
                lightThemeName: current.lightThemeName,
                usePerAppearanceTheme: current.usePerAppearanceTheme
            )
        case .light:
            requested = TerminalThemeSelection(
                darkThemeName: current.darkThemeName,
                lightThemeName: themeName,
                usePerAppearanceTheme: current.usePerAppearanceTheme
            )
        case .both:
            requested = TerminalThemeSelection(
                darkThemeName: themeName,
                lightThemeName: themeName,
                usePerAppearanceTheme: current.usePerAppearanceTheme
            )
        }

        applyLocalSelection(requested)
    }

    func setUsesPerAppearanceTheme(_ enabled: Bool) {
        applyLocalSelection(
            TerminalThemeSelection(
                darkThemeName: themeSelection.darkThemeName,
                lightThemeName: themeSelection.lightThemeName,
                usePerAppearanceTheme: enabled
            )
        )
    }

    func appearanceSnapshot(
        for activeAppearance: TerminalColorAppearance
    ) -> TerminalAppearanceSnapshot {
        let darkTheme = resolvedTheme(
            preferred: themeSelection.darkThemeName,
            fallback: "Aizen Dark"
        )
        let lightTheme = themeSelection.usePerAppearanceTheme
            ? resolvedTheme(
                preferred: themeSelection.lightThemeName,
                fallback: "Aizen Light"
            )
            : darkTheme

        return TerminalAppearanceSnapshot(
            activeAppearance: activeAppearance,
            lightTheme: lightTheme,
            darkTheme: darkTheme
        )
    }

    @discardableResult
    func activateAppearance(
        _ appearance: TerminalColorAppearance
    ) -> TerminalAppearanceSnapshot {
        let snapshot = appearanceSnapshot(for: appearance)
        if activeAppearanceSnapshot != snapshot {
            activeAppearanceSnapshot = snapshot
        }

        let backgroundHex = snapshot.activeTheme.palette.backgroundHex
        persistence.cacheActiveBackgroundHex(backgroundHex)
        return snapshot
    }

    func suggestThemeName(from sourceName: String?) -> String {
        let trimmed = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return uniqueThemeName(from: "Custom Theme")
        }
        let sanitized = sanitizeThemeName(trimmed)
        return uniqueThemeName(from: sanitized.isEmpty ? "Custom Theme" : sanitized)
    }

    func createCustomTheme(name: String, content: String) throws -> TerminalTheme {
        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let finalName = try TerminalThemeValidator.validateAndNormalizeThemeName(
            uniqueThemeName(from: sanitized)
        )

        let theme = TerminalTheme(
            name: finalName,
            content: normalizedContent,
            updatedAt: dependencies.now(),
            deletedAt: nil
        )

        customThemes.append(theme)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        pushThemeToCloud(theme)
        return theme
    }

    @discardableResult
    func updateCustomTheme(id: UUID, name: String, content: String) throws -> TerminalTheme {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TerminalThemeValidationError.themeNotFound
        }

        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let previousName = customThemes[index].name
        let finalName = try TerminalThemeValidator.validateAndNormalizeThemeName(
            uniqueThemeName(from: sanitized, excludingThemeID: id)
        )
        let now = dependencies.now()

        customThemes[index].name = finalName
        customThemes[index].content = normalizedContent
        customThemes[index].updatedAt = now
        customThemes[index].deletedAt = nil

        migrateSelectionsForRenamedTheme(from: previousName, to: finalName)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        pushThemeToCloud(customThemes[index])

        return customThemes[index]
    }

    func deleteCustomTheme(named name: String) {
        guard let index = customThemes.firstIndex(where: { $0.name == name && !$0.isDeleted }) else {
            return
        }

        deleteTheme(at: index)
    }

    func deleteCustomTheme(id: UUID) {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        deleteTheme(at: index)
    }

    private func deleteTheme(at index: Int) {
        let now = dependencies.now()
        customThemes[index].deletedAt = now
        customThemes[index].updatedAt = now
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
        pushThemeToCloud(customThemes[index])
    }

    private func loadThemes() {
        do {
            customThemes = try persistence.loadCustomThemes()
        } catch {
            customThemes = []
            logger.error("Failed to load custom themes: \(error.localizedDescription)")
        }
    }

    private func saveThemes() {
        do {
            try persistence.saveCustomThemes(customThemes)
        } catch {
            logger.error("Failed to save custom themes: \(error.localizedDescription)")
        }
    }

    private func syncCustomThemeFiles() {
        defer { dependencies.paletteResolver.invalidateCache() }

        do {
            try dependencies.themeFiles.synchronize(customThemes)
        } catch {
            logger.error("Failed to sync custom theme files: \(error.localizedDescription)")
        }
    }

    private func ensureThemeSelectionIsValid() {
        let selection = currentPreferenceSnapshot()
        let correctedSelection = normalizedSelection(selection)

        if correctedSelection != selection {
            persistence.saveSelection(correctedSelection)
            lastKnownPreferenceSnapshot = correctedSelection
        }
    }

    private func sanitizeThemeName(_ name: String) -> String {
        var sanitized = name.replacingOccurrences(of: "/", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "-")
        sanitized = sanitized.replacingOccurrences(of: ":", with: "-")
        sanitized = String(sanitized.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "." || trimmed == ".." ? "" : trimmed
    }

    private func uniqueThemeName(from baseName: String, excludingThemeID: UUID? = nil) -> String {
        let builtIn = Set(
            dependencies.builtInThemeCatalog.themeNames().map(normalizedThemeNameKey(_:))
        )
        let existing = Set(
            customThemes
                .filter { !$0.isDeleted && $0.id != excludingThemeID }
                .map { normalizedThemeNameKey($0.name) }
        )
        let maxLength = 80

        var root = String(baseName.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty { root = "Custom Theme" }

        if !builtIn.contains(normalizedThemeNameKey(root)) &&
            !existing.contains(normalizedThemeNameKey(root)) {
            return root
        }

        var index = 2
        while true {
            let suffix = " \(index)"
            let availableRootLength = max(1, maxLength - suffix.count)
            let candidateRoot = String(root.prefix(availableRootLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = "\(candidateRoot)\(suffix)"
            if !builtIn.contains(normalizedThemeNameKey(candidate)) &&
                !existing.contains(normalizedThemeNameKey(candidate)) {
                return candidate
            }
            index += 1
        }
    }

    private func normalizedThemeNameKey(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func migrateSelectionsForRenamedTheme(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        let selection = currentPreferenceSnapshot()
        let migratedSelection = TerminalThemeSelection(
            darkThemeName: selection.darkThemeName == oldName
                ? newName
                : selection.darkThemeName,
            lightThemeName: selection.lightThemeName == oldName
                ? newName
                : selection.lightThemeName,
            usePerAppearanceTheme: selection.usePerAppearanceTheme
        )
        guard migratedSelection != selection else { return }
        persistence.saveSelection(migratedSelection)
    }

    private func observeThemePreferenceChanges(cleanup: TerminalThemeObserverCleanup) {
        let observer = dependencies.preferenceChanges.observeChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleThemePreferenceChange()
            }
        }
        cleanup.registerPreferenceObserver(observer)
    }

    private func observeSyncLifecycle(cleanup: TerminalThemeObserverCleanup) {
        let observerID = dependencies.syncLifecycle.observe { [weak self] event in
            self?.handleSyncLifecycleEvent(event)
        }
        cleanup.registerLifecycleObserver(observerID)
    }

    private func handleThemePreferenceChange() {
        guard !isApplyingRemotePreference else { return }
        let storedSelection = currentPreferenceSnapshot()
        let snapshot = normalizedSelection(storedSelection)
        let selectionChanged = snapshot != lastKnownPreferenceSnapshot
        lastKnownPreferenceSnapshot = snapshot
        if snapshot != storedSelection {
            persistence.saveSelection(snapshot)
        }
        guard selectionChanged else { return }
        refreshActiveAppearance()

        let now = dependencies.now()
        persistence.savePreferenceUpdatedAt(now)
        schedulePreferenceCloudSync(
            TerminalThemePreference(
                darkThemeName: snapshot.darkThemeName,
                lightThemeName: snapshot.lightThemeName,
                usePerAppearanceTheme: snapshot.usePerAppearanceTheme,
                updatedAt: now
            )
        )
    }

    private func currentPreferenceSnapshot() -> TerminalThemeSelection {
        persistence.loadSelection()
    }

    private func normalizedSelection(
        _ selection: TerminalThemeSelection
    ) -> TerminalThemeSelection {
        let storedThemeNames = customThemes.filter { !$0.isDeleted }.map(\.name)
        let available = Set(dependencies.builtInThemeCatalog.themeNames() + storedThemeNames)
        return TerminalThemeSelection(
            darkThemeName: available.contains(selection.darkThemeName)
                ? selection.darkThemeName
                : "Aizen Dark",
            lightThemeName: available.contains(selection.lightThemeName)
                ? selection.lightThemeName
                : "Aizen Light",
            usePerAppearanceTheme: selection.usePerAppearanceTheme
        )
    }

    private func applyLocalSelection(_ requested: TerminalThemeSelection) {
        let selection = normalizedSelection(requested)
        guard selection != themeSelection else { return }

        themeSelection = selection
        lastKnownPreferenceSnapshot = selection
        persistence.saveSelection(selection)
        _ = activateAppearance(activeAppearanceSnapshot.activeAppearance)

        guard dependencies.startsSynchronization else { return }
        let now = dependencies.now()
        persistence.savePreferenceUpdatedAt(now)
        schedulePreferenceCloudSync(
            TerminalThemePreference(
                darkThemeName: selection.darkThemeName,
                lightThemeName: selection.lightThemeName,
                usePerAppearanceTheme: selection.usePerAppearanceTheme,
                updatedAt: now
            )
        )
    }

    private func localPreferenceUpdatedAt() -> Date {
        persistence.loadPreferenceUpdatedAt()
    }

    private func schedulePreferenceCloudSync(_ preference: TerminalThemePreference) {
        pendingPreferenceSyncTask?.cancel()
        let waitForPreferenceSyncDebounce = dependencies.waitForPreferenceSyncDebounce
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        let logger = logger
        pendingPreferenceSyncTask = Task { [waitForPreferenceSyncDebounce, isSyncEnabled, mutationQueue, preference, logger] in
            try? await waitForPreferenceSyncDebounce()
            guard !Task.isCancelled else { return }
            guard !Task.isCancelled, isSyncEnabled() else { return }
            do {
                try mutationQueue.enqueueTerminalThemePreferenceUpsert(preference)
            } catch {
                logger.error(
                    "Failed to persist terminal theme preference sync: \(error.localizedDescription)"
                )
                return
            }
            guard !Task.isCancelled, isSyncEnabled() else { return }
            await mutationQueue.drainPendingMutations()
        }
    }

    private func pushThemeToCloud(_ theme: TerminalTheme) {
        let isSyncEnabled = dependencies.isSyncEnabled
        let mutationQueue = dependencies.mutationQueue
        let logger = logger
        Task { @MainActor [isSyncEnabled, mutationQueue, theme, logger] in
            guard isSyncEnabled() else { return }
            do {
                try mutationQueue.enqueueTerminalThemeUpsert(theme)
            } catch {
                logger.error(
                    "Failed to persist terminal theme sync: \(error.localizedDescription)"
                )
                return
            }
            guard !Task.isCancelled, isSyncEnabled() else { return }
            await mutationQueue.drainPendingMutations()
        }
    }

    private func makeCloudSyncTask() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synchronizeWithCloud()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.dependencies.isSyncEnabled() else { return }
                self.logger.warning("Custom theme CloudKit sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func synchronizeWithCloud() async throws {
        try Task.checkCancellation()
        guard dependencies.isSyncEnabled() else { return }
        let localThemesSnapshot = customThemes
        let remoteThemes = try await dependencies.cloud.fetchTerminalThemes()
        try Task.checkCancellation()
        guard dependencies.isSyncEnabled() else { throw CancellationError() }
        try applyRemoteThemesAndEnqueueMissing(
            remoteThemes,
            localThemesSnapshot: localThemesSnapshot,
            mutationQueue: dependencies.mutationQueue
        )

        let remotePreference = try await dependencies.cloud.fetchTerminalThemePreference()
        try Task.checkCancellation()
        guard dependencies.isSyncEnabled() else { throw CancellationError() }
        try applyRemotePreferenceOrEnqueueLocal(
            remotePreference,
            mutationQueue: dependencies.mutationQueue
        )

        await dependencies.mutationQueue.drainPendingMutations()
    }

    private func applyRemoteThemesAndEnqueueMissing(
        _ remoteThemes: [TerminalTheme],
        localThemesSnapshot: [TerminalTheme],
        mutationQueue: any TerminalThemeMutationQueue
    ) throws {
        var remoteByID: [UUID: TerminalTheme] = [:]
        for remoteTheme in remoteThemes {
            guard let validTheme = try? TerminalThemeValidator.validateStoredTheme(remoteTheme) else {
                continue
            }
            if let existing = remoteByID[validTheme.id],
               existing.updatedAt >= validTheme.updatedAt {
                continue
            }
            remoteByID[validTheme.id] = validTheme
        }

        mergeRemoteThemes(remoteThemes)

        for localTheme in localThemesSnapshot {
            if let remoteTheme = remoteByID[localTheme.id],
               remoteTheme.updatedAt >= localTheme.updatedAt {
                continue
            }
            try mutationQueue.enqueueTerminalThemeUpsert(localTheme)
        }
    }

    private func applyRemotePreferenceOrEnqueueLocal(
        _ remotePreference: TerminalThemePreference?,
        mutationQueue: any TerminalThemeMutationQueue
    ) throws {
        if let remotePreference {
            applyRemotePreferenceIfNewer(remotePreference)
            return
        }

        let localUpdatedAt = localPreferenceUpdatedAt()
        let seedUpdatedAt: Date
        if localUpdatedAt == .distantPast {
            seedUpdatedAt = dependencies.now()
            persistence.savePreferenceUpdatedAt(seedUpdatedAt)
        } else {
            seedUpdatedAt = localUpdatedAt
        }

        let selection = currentPreferenceSnapshot()
        try mutationQueue.enqueueTerminalThemePreferenceUpsert(
            TerminalThemePreference(
                darkThemeName: selection.darkThemeName,
                lightThemeName: selection.lightThemeName,
                usePerAppearanceTheme: selection.usePerAppearanceTheme,
                updatedAt: seedUpdatedAt
            )
        )
    }

    private func handleSyncLifecycleEvent(_ event: CloudKitSyncLifecycleEvent) {
        switch event {
        case .foreground, .syncEnabled:
            startupSyncTask?.cancel()
            startupSyncTask = nil
            lifecycleSyncTask?.cancel()
            lifecycleSyncTask = makeCloudSyncTask()
        case .syncDisabled:
            pendingPreferenceSyncTask?.cancel()
            pendingPreferenceSyncTask = nil
            startupSyncTask?.cancel()
            startupSyncTask = nil
            lifecycleSyncTask?.cancel()
            lifecycleSyncTask = nil
        }
    }

    private func mergeRemoteThemes(_ remoteThemes: [TerminalTheme]) {
        customThemes = TerminalThemeMergePolicy.merge(local: customThemes, remote: remoteThemes)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        refreshActiveAppearance()
    }

    private func applyRemotePreferenceIfNewer(_ preference: TerminalThemePreference) {
        let localUpdatedAt = localPreferenceUpdatedAt()
        guard preference.updatedAt > localUpdatedAt else { return }

        isApplyingRemotePreference = true
        persistence.saveSelection(
            TerminalThemeSelection(
                darkThemeName: preference.darkThemeName,
                lightThemeName: preference.lightThemeName,
                usePerAppearanceTheme: preference.usePerAppearanceTheme
            )
        )
        persistence.savePreferenceUpdatedAt(preference.updatedAt)
        isApplyingRemotePreference = false

        ensureThemeSelectionIsValid()
        lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
        refreshActiveAppearance()
    }

    private func resolvedTheme(
        preferred: String,
        fallback: String
    ) -> ResolvedTerminalTheme {
        let name = applicationThemeName(preferred: preferred, fallback: fallback)
        let palette: TerminalThemePalette
        if let customTheme = customThemes.first(where: {
            !$0.isDeleted && $0.canApply && $0.name == name
        }) {
            palette = dependencies.paletteResolver.palette(
                forThemeContent: customTheme.content
            )
        } else {
            palette = dependencies.paletteResolver.palette(forThemeNamed: name)
        }
        return ResolvedTerminalTheme(
            name: name,
            palette: palette
        )
    }

    private func refreshActiveAppearance() {
        let selection = currentPreferenceSnapshot()
        if themeSelection != selection {
            themeSelection = selection
        }
        _ = activateAppearance(activeAppearanceSnapshot.activeAppearance)
    }
}
