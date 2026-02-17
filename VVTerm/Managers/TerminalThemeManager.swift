//
//  TerminalThemeManager.swift
//  VVTerm
//

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TerminalThemeStoragePaths {
    nonisolated static func customThemesDirectoryURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundleComponent = Bundle.main.bundleIdentifier ?? "app.vivy.vvterm"
        return appSupport
            .appendingPathComponent(bundleComponent, isDirectory: true)
            .appendingPathComponent("CustomThemes", isDirectory: true)
    }

    nonisolated static func customThemesDirectoryPath() -> String {
        customThemesDirectoryURL().path
    }

    nonisolated static func customThemeFilePath(for themeName: String) -> String {
        customThemesDirectoryURL().appendingPathComponent(themeName).path
    }
}

enum TerminalThemeValidationError: LocalizedError {
    case emptyContent
    case invalidLine(line: Int)
    case invalidHex(line: Int)
    case invalidPalette(line: Int)
    case missingRequiredKey(String)
    case invalidName
    case themeNotFound

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return String(localized: "Theme content is empty.")
        case .invalidLine(let line):
            return String(
                format: String(localized: "Invalid theme line %lld. Expected key/value format."),
                Int64(line)
            )
        case .invalidHex(let line):
            return String(
                format: String(localized: "Invalid hex color at line %lld. Use #RRGGBB."),
                Int64(line)
            )
        case .invalidPalette(let line):
            return String(
                format: String(localized: "Invalid palette value at line %lld. Expected N=#RRGGBB where N is 0...15."),
                Int64(line)
            )
        case .missingRequiredKey(let key):
            return String(
                format: String(localized: "Theme is missing required key: %@."),
                key
            )
        case .invalidName:
            return String(localized: "Theme name contains invalid characters.")
        case .themeNotFound:
            return String(localized: "Theme no longer exists.")
        }
    }
}

enum TerminalThemeValidator {
    private static let colorKeys = Set([
        "background",
        "foreground",
        "cursor-color",
        "cursor-text",
        "selection-background",
        "selection-foreground"
    ])

    nonisolated static func isValidHexColor(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        guard hex.count == 6 else { return false }
        return hex.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0)
        }
    }

    nonisolated static func normalizeHexColor(_ value: String) -> String? {
        guard isValidHexColor(value) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        return "#\(hex.uppercased())"
    }

    nonisolated static func validateAndNormalizeThemeContent(_ rawContent: String) throws -> String {
        let lines = rawContent.components(separatedBy: .newlines)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TerminalThemeValidationError.emptyContent
        }

        var normalizedLines: [String] = []
        var seenBackground = false
        var seenForeground = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw TerminalThemeValidationError.invalidLine(line: lineNumber)
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "palette" {
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                guard paletteParts.count == 2,
                      let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      (0...15).contains(index),
                      let color = normalizeHexColor(String(paletteParts[1])) else {
                    throw TerminalThemeValidationError.invalidPalette(line: lineNumber)
                }
                normalizedLines.append("palette = \(index)=\(color)")
                continue
            }

            if colorKeys.contains(key) {
                guard let color = normalizeHexColor(value) else {
                    throw TerminalThemeValidationError.invalidHex(line: lineNumber)
                }
                normalizedLines.append("\(key) = \(color)")

                if key == "background" { seenBackground = true }
                if key == "foreground" { seenForeground = true }
                continue
            }

            normalizedLines.append("\(key) = \(value)")
        }

        guard seenBackground else {
            throw TerminalThemeValidationError.missingRequiredKey("background")
        }
        guard seenForeground else {
            throw TerminalThemeValidationError.missingRequiredKey("foreground")
        }

        return normalizedLines.joined(separator: "\n") + "\n"
    }
}

@MainActor
final class TerminalThemeManager: ObservableObject {
    static let shared = TerminalThemeManager()

    @Published private(set) var customThemes: [TerminalTheme] = []

    private struct PreferenceSnapshot: Equatable {
        var darkThemeName: String
        var lightThemeName: String
        var usePerAppearanceTheme: Bool
    }

    private let defaults: UserDefaults
    private let cloudKit: CloudKitManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "TerminalThemeManager")

    private let customThemesKey = "terminalCustomThemesV1"
    private let darkThemeKey = "terminalThemeName"
    private let lightThemeKey = "terminalThemeNameLight"
    private let perAppearanceThemeKey = "terminalUsePerAppearanceTheme"
    private let preferenceUpdatedAtKey = "terminalThemePreferenceUpdatedAt"

    private var defaultsObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var lastKnownPreferenceSnapshot: PreferenceSnapshot
    private var isApplyingRemotePreference = false
    private var pendingPreferenceSyncTask: Task<Void, Never>?

    private init(defaults: UserDefaults = .standard, cloudKit: CloudKitManager = .shared) {
        self.defaults = defaults
        self.cloudKit = cloudKit
        self.lastKnownPreferenceSnapshot = PreferenceSnapshot(
            darkThemeName: defaults.string(forKey: darkThemeKey) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: lightThemeKey) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: perAppearanceThemeKey) as? Bool ?? true
        )

        loadThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        observeThemePreferenceChanges()
        observeForegroundSync()

        Task {
            await syncFromCloud()
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        pendingPreferenceSyncTask?.cancel()
    }

    var customThemeNames: [String] {
        customThemes
            .filter { !$0.isDeleted }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func builtInThemeNames() -> [String] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let fm = FileManager.default

        let structuredPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        if fm.fileExists(atPath: structuredPath),
           let files = try? fm.contentsOfDirectory(atPath: structuredPath) {
            return files
                .filter { file in
                    let fullPath = (structuredPath as NSString).appendingPathComponent(file)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    return !isDir.boolValue && !file.hasPrefix(".")
                }
                .sorted()
        }

        guard let files = try? fm.contentsOfDirectory(atPath: resourcePath) else { return [] }
        let knownNonThemes = Set([
            "Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty",
            "CodeSignature", "embedded", "_CodeSignature"
        ])
        return files
            .filter { file in
                let fullPath = (resourcePath as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                guard !isDir.boolValue else { return false }
                guard !file.hasPrefix(".") else { return false }
                guard !file.contains(".") else { return false }
                guard !knownNonThemes.contains(file) else { return false }
                return true
            }
            .sorted()
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
        let finalName = uniqueThemeName(from: sanitized)

        let theme = TerminalTheme(
            name: finalName,
            content: normalizedContent,
            updatedAt: Date(),
            deletedAt: nil
        )

        customThemes.append(theme)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
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
        let finalName = uniqueThemeName(from: sanitized, excludingThemeID: id)
        let now = Date()

        customThemes[index].name = finalName
        customThemes[index].content = normalizedContent
        customThemes[index].updatedAt = now
        customThemes[index].deletedAt = nil

        migrateSelectionsForRenamedTheme(from: previousName, to: finalName)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
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
        customThemes[index].deletedAt = Date()
        customThemes[index].updatedAt = Date()
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
        pushThemeToCloud(customThemes[index])
    }

    private func loadThemes() {
        guard let data = defaults.data(forKey: customThemesKey) else {
            customThemes = []
            return
        }
        do {
            customThemes = try JSONDecoder().decode([TerminalTheme].self, from: data)
        } catch {
            customThemes = []
            logger.error("Failed to decode custom themes: \(error.localizedDescription)")
        }
    }

    private func saveThemes() {
        do {
            let data = try JSONEncoder().encode(customThemes)
            defaults.set(data, forKey: customThemesKey)
        } catch {
            logger.error("Failed to encode custom themes: \(error.localizedDescription)")
        }
    }

    private func syncCustomThemeFiles() {
        let fm = FileManager.default
        let directoryURL = TerminalThemeStoragePaths.customThemesDirectoryURL()

        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let visibleThemes = customThemes.filter { !$0.isDeleted }
            let visibleNames = Set(visibleThemes.map(\.name))

            let existingFiles = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            for file in existingFiles {
                guard !visibleNames.contains(file.lastPathComponent) else { continue }
                try? fm.removeItem(at: file)
            }

            for theme in visibleThemes {
                let fileURL = directoryURL.appendingPathComponent(theme.name)
                try theme.content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to sync custom theme files: \(error.localizedDescription)")
        }
    }

    private func ensureThemeSelectionIsValid() {
        let available = Set(Self.builtInThemeNames() + customThemeNames)
        let fallbackDark = "Aizen Dark"
        let fallbackLight = "Aizen Light"

        let darkTheme = defaults.string(forKey: darkThemeKey) ?? fallbackDark
        let lightTheme = defaults.string(forKey: lightThemeKey) ?? fallbackLight

        var changed = false
        if !available.contains(darkTheme) {
            defaults.set(fallbackDark, forKey: darkThemeKey)
            changed = true
        }
        if !available.contains(lightTheme) {
            defaults.set(fallbackLight, forKey: lightThemeKey)
            changed = true
        }

        if changed {
            lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
        }
    }

    private func sanitizeThemeName(_ name: String) -> String {
        var sanitized = name.replacingOccurrences(of: "/", with: "-")
        sanitized = sanitized.replacingOccurrences(of: ":", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "\n", with: " ")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: " ")
        sanitized = sanitized.replacingOccurrences(of: "\t", with: " ")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueThemeName(from baseName: String, excludingThemeID: UUID? = nil) -> String {
        let builtIn = Set(Self.builtInThemeNames().map(normalizedThemeNameKey(_:)))
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

        if defaults.string(forKey: darkThemeKey) == oldName {
            defaults.set(newName, forKey: darkThemeKey)
        }

        if defaults.string(forKey: lightThemeKey) == oldName {
            defaults.set(newName, forKey: lightThemeKey)
        }
    }

    private func observeThemePreferenceChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThemePreferenceChange()
            }
        }
    }

    private func observeForegroundSync() {
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        return
        #endif

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncFromCloud()
            }
        }
    }

    private func handleThemePreferenceChange() {
        guard !isApplyingRemotePreference else { return }
        let snapshot = currentPreferenceSnapshot()
        guard snapshot != lastKnownPreferenceSnapshot else { return }
        lastKnownPreferenceSnapshot = snapshot

        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
        schedulePreferenceCloudSync(
            TerminalThemePreference(
                darkThemeName: snapshot.darkThemeName,
                lightThemeName: snapshot.lightThemeName,
                usePerAppearanceTheme: snapshot.usePerAppearanceTheme,
                updatedAt: now
            )
        )
    }

    private func currentPreferenceSnapshot() -> PreferenceSnapshot {
        PreferenceSnapshot(
            darkThemeName: defaults.string(forKey: darkThemeKey) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: lightThemeKey) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: perAppearanceThemeKey) as? Bool ?? true
        )
    }

    private func localPreferenceUpdatedAt() -> Date {
        let value = defaults.double(forKey: preferenceUpdatedAtKey)
        guard value > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: value)
    }

    private func schedulePreferenceCloudSync(_ preference: TerminalThemePreference) {
        pendingPreferenceSyncTask?.cancel()
        pendingPreferenceSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushPreferenceToCloud(preference)
        }
    }

    private func pushThemeToCloud(_ theme: TerminalTheme) {
        Task { [weak self] in
            guard let self else { return }
            guard SyncSettings.isEnabled else { return }
            do {
                try await self.cloudKit.saveTerminalTheme(theme)
            } catch {
                self.logger.warning("Failed to sync custom theme '\(theme.name)': \(error.localizedDescription)")
            }
        }
    }

    private func pushPreferenceToCloud(_ preference: TerminalThemePreference) async {
        guard SyncSettings.isEnabled else { return }
        do {
            try await cloudKit.saveTerminalThemePreference(preference)
        } catch {
            logger.warning("Failed to sync terminal theme preference: \(error.localizedDescription)")
        }
    }

    private func syncFromCloud() async {
        guard SyncSettings.isEnabled else { return }

        do {
            let localSnapshot = customThemes
            let remoteThemes = try await cloudKit.fetchTerminalThemes()
            let remoteByID = Dictionary(uniqueKeysWithValues: remoteThemes.map { ($0.id, $0) })

            mergeRemoteThemes(remoteThemes)

            for localTheme in localSnapshot {
                if let remoteTheme = remoteByID[localTheme.id],
                   remoteTheme.updatedAt >= localTheme.updatedAt {
                    continue
                }
                pushThemeToCloud(localTheme)
            }

            if let remotePreference = try await cloudKit.fetchTerminalThemePreference() {
                applyRemotePreferenceIfNewer(remotePreference)
            } else {
                let localUpdatedAt = localPreferenceUpdatedAt()
                let seedUpdatedAt: Date
                if localUpdatedAt == .distantPast {
                    seedUpdatedAt = Date()
                    defaults.set(seedUpdatedAt.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
                } else {
                    seedUpdatedAt = localUpdatedAt
                }

                let localPreference = TerminalThemePreference(
                    darkThemeName: currentPreferenceSnapshot().darkThemeName,
                    lightThemeName: currentPreferenceSnapshot().lightThemeName,
                    usePerAppearanceTheme: currentPreferenceSnapshot().usePerAppearanceTheme,
                    updatedAt: seedUpdatedAt
                )
                await pushPreferenceToCloud(localPreference)
            }
        } catch {
            logger.warning("Custom theme CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func mergeRemoteThemes(_ remoteThemes: [TerminalTheme]) {
        var localByID = Dictionary(uniqueKeysWithValues: customThemes.map { ($0.id, $0) })

        for remoteTheme in remoteThemes {
            if let localTheme = localByID[remoteTheme.id] {
                if remoteTheme.updatedAt > localTheme.updatedAt {
                    localByID[remoteTheme.id] = remoteTheme
                }
            } else {
                localByID[remoteTheme.id] = remoteTheme
            }
        }

        customThemes = Array(localByID.values)
        saveThemes()
        syncCustomThemeFiles()
        ensureThemeSelectionIsValid()
    }

    private func applyRemotePreferenceIfNewer(_ preference: TerminalThemePreference) {
        let localUpdatedAt = localPreferenceUpdatedAt()
        guard preference.updatedAt > localUpdatedAt else { return }

        isApplyingRemotePreference = true
        defaults.set(preference.darkThemeName, forKey: darkThemeKey)
        defaults.set(preference.lightThemeName, forKey: lightThemeKey)
        defaults.set(preference.usePerAppearanceTheme, forKey: perAppearanceThemeKey)
        defaults.set(preference.updatedAt.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
        isApplyingRemotePreference = false

        ensureThemeSelectionIsValid()
        lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
    }
}
