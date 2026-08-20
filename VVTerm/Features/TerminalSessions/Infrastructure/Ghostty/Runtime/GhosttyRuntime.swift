//
//  GhosttyRuntime.swift
//  VVTerm
//
//  Ghostty runtime lifecycle owner
//

import Foundation
import Combine
import OSLog

/// Owns the native Ghostty application lifecycle.
@MainActor
final class GhosttyRuntime: ObservableObject {
    enum Readiness: String {
        case idle, loading, error, ready, stopped
    }

    private enum RuntimeState {
        case idle
        case loading
        case failed
        case ready(
            app: ghostty_app_t,
            callbackContext: Ghostty.CallbackContext<GhosttyRuntime>
        )
        case stopped

        var app: ghostty_app_t? {
            guard case .ready(let app, _) = self else { return nil }
            return app
        }

        var readiness: Readiness {
            switch self {
            case .idle:
                return .idle
            case .loading:
                return .loading
            case .failed:
                return .error
            case .ready:
                return .ready
            case .stopped:
                return .stopped
            }
        }
    }

    // MARK: - Runtime State

    /// The ghostty app instance
    var app: ghostty_app_t? { runtimeState.app }

    /// Readiness state
    var readiness: Readiness { runtimeState.readiness }

    @Published private var runtimeState: RuntimeState = .idle

    /// Resolved appearance supplied by the terminal appearance owner.
    private(set) var appearanceSnapshot: TerminalAppearanceSnapshot

    /// Terminal settings supplied by the app composition root.
    private(set) var configuration: Ghostty.RuntimeConfiguration

    /// Track active surfaces for config propagation
    private var activeSurfaces: [Ghostty.SurfaceReference] = []
    private var surfaceConfigCache: [SurfaceConfigCacheKey: ghostty_config_t] = [:]

    // MARK: - Initialization

    private struct SurfaceConfigCacheKey: Hashable {
        let fontName: String
        let fontSize: Double
        let themeName: String
        let cursorStyleRaw: String
        let cursorBlink: Bool
        let optionAsAltModeRaw: String
    }

    convenience init(
        appearance: TerminalAppearanceSnapshot = .fallback,
        autoStart: Bool = true
    ) {
        self.init(
            configuration: .defaultValue,
            appearance: appearance,
            autoStart: autoStart
        )
    }

    init(
        configuration: Ghostty.RuntimeConfiguration,
        appearance: TerminalAppearanceSnapshot = .fallback,
        autoStart: Bool = true
    ) {
        self.configuration = configuration
        appearanceSnapshot = appearance
        if autoStart {
            startIfNeeded()
        }
    }

    func startIfNeeded(appearance: TerminalAppearanceSnapshot? = nil) {
        if let appearance {
            applyAppearance(appearance)
        }
        guard case .idle = runtimeState else { return }
        runtimeState = .loading
        start()
    }

    private func start() {
        ensureProcessEnvironment()

        // CRITICAL: Initialize libghostty first
        let initResult = ghostty_init(0, nil)
        if initResult != GHOSTTY_SUCCESS {
            Ghostty.logger.critical("ghostty_init failed with code: \(initResult)")
            runtimeState = .failed
            return
        }

        // iPhone touch selection now owns copy explicitly, so don't let
        // Ghostty mirror selection changes into the pasteboard on iOS.
        #if os(iOS)
        let supportsSelectionClipboard = false
        #else
        let supportsSelectionClipboard = true
        #endif

        // Create runtime config with callbacks
        let callbackContext = Ghostty.CallbackContext(owner: self)
        var runtime_cfg = Self.makeRuntimeConfiguration(
            userdata: callbackContext.userdata,
            supportsSelectionClipboard: supportsSelectionClipboard
        )

        // Create config and load VVTerm terminal settings
        guard let config = ghostty_config_new() else {
            Ghostty.logger.critical("ghostty_config_new failed")
            callbackContext.invalidate()
            runtimeState = .failed
            return
        }

        // Load config from settings
        loadConfigIntoGhostty(config)

        // Finalize config (required before use)
        ghostty_config_finalize(config)

        // Create the ghostty app
        guard let app = ghostty_app_new(&runtime_cfg, config) else {
            Ghostty.logger.critical("ghostty_app_new failed")
            ghostty_config_free(config)
            callbackContext.invalidate()
            runtimeState = .failed
            return
        }

        // Free config after app creation (app clones it)
        ghostty_config_free(config)

        // CRITICAL: Unset XDG_CONFIG_HOME after app creation
        // If left set, fish will look for config.fish in the temp directory instead of ~/.config
        unsetenv("XDG_CONFIG_HOME")

        runtimeState = .ready(
            app: app,
            callbackContext: callbackContext
        )

        Ghostty.logger.info("Ghostty app initialized successfully")
    }

    private func ensureProcessEnvironment() {
        #if os(iOS)
        let homeDirectory = NSHomeDirectory()
        if !homeDirectory.isEmpty {
            if let currentHome = getenv("HOME"), !String(cString: currentHome).isEmpty {
                // Keep the system-provided value when it exists.
            } else {
                setenv("HOME", homeDirectory, 1)
            }
        }

        let temporaryDirectory = NSTemporaryDirectory()
        if !temporaryDirectory.isEmpty {
            if let currentTemporaryDirectory = getenv("TMPDIR"),
               !String(cString: currentTemporaryDirectory).isEmpty {
                // Keep the system-provided value when it exists.
            } else {
                setenv("TMPDIR", temporaryDirectory, 1)
            }
        }
        #endif
    }

    deinit {
        // Native app cleanup is explicit because its surfaces must be freed first.
    }

    // MARK: - App Operations

    /// Clean up the ghostty app resources
    func cleanup() {
        clearSurfaceConfigCache()
        guard case .ready(let app, let callbackContext) = runtimeState else { return }
        callbackContext.invalidate()
        ghostty_app_free(app)
        runtimeState = .stopped
    }

    func appTick() {
        guard let app = self.app else { return }
        ghostty_app_tick(app)
    }

    /// Register a surface for config update tracking
    /// Returns the surface reference that should be stored by the view
    @discardableResult
    func registerSurface(_ surface: ghostty_surface_t, terminalView: GhosttyTerminalView) -> Ghostty.SurfaceReference {
        removeReleasedSurfaceReferences()
        let ref = Ghostty.SurfaceReference(surface, terminalView: terminalView)
        activeSurfaces.append(ref)
        return ref
    }

    /// Unregister a surface when it's being deallocated
    func unregisterSurface(_ ref: Ghostty.SurfaceReference) {
        activeSurfaces.removeAll { $0 === ref || $0.terminalView == nil }
    }

    func terminalView(for surface: ghostty_surface_t) -> GhosttyTerminalView? {
        removeReleasedSurfaceReferences()
        return activeSurfaces.first { $0.surface == surface }?.terminalView
    }

    func activeSurfaceCount() -> Int {
        removeReleasedSurfaceReferences()
        return activeSurfaces.count
    }

    /// Reload configuration (call when settings change)
    func reloadConfig() {
        guard let app = self.app else { return }
        clearSurfaceConfigCache()

        // Create new config with updated settings
        guard let config = makeConfig(refreshThemes: true) else { return }

        // Update the app config
        ghostty_app_update_config(app, config)

        // Propagate config to all existing surfaces
        removeReleasedSurfaceReferences()
        for surfaceRef in activeSurfaces {
            if let presentationOverrides = surfaceRef.terminalView?.surfacePresentationOverrides,
               !presentationOverrides.isEmpty,
               let surfaceConfig = cachedSurfaceConfig(for: presentationOverrides) {
                ghostty_surface_update_config(surfaceRef.surface, surfaceConfig)
            } else {
                ghostty_surface_update_config(surfaceRef.surface, config)
            }
        }

        ghostty_config_free(config)

        // Unset XDG_CONFIG_HOME so it doesn't affect fish/shell config loading
        unsetenv("XDG_CONFIG_HOME")

        Ghostty.logger.info("Configuration reloaded and propagated to \(self.activeSurfaces.count) surfaces")

        // Notify views to refresh their rendering
        NotificationCenter.default.post(name: Ghostty.configDidReloadNotification, object: nil)
    }

    func applyConfiguration(_ configuration: Ghostty.RuntimeConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        guard case .ready = runtimeState else { return }
        reloadConfig()
    }

    func applyAppearance(_ snapshot: TerminalAppearanceSnapshot) {
        guard appearanceSnapshot != snapshot else { return }
        appearanceSnapshot = snapshot
        guard case .ready = runtimeState else { return }
        Ghostty.logger.info(
            "Terminal appearance changed; reloading theme: \(snapshot.activeTheme.name)"
        )
        reloadConfig()
    }

    func updateSurfaceConfig(_ surface: ghostty_surface_t, presentationOverrides: TerminalPresentationOverrides) {
        guard let config = cachedSurfaceConfig(for: presentationOverrides) else { return }
        ghostty_surface_update_config(surface, config)
        unsetenv("XDG_CONFIG_HOME")
        Ghostty.logger.info("Updated surface presentation overrides")
    }

    // MARK: - Private Helpers

    private func makeConfig(
        presentationOverrides: TerminalPresentationOverrides = .empty,
        refreshThemes: Bool
    ) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            Ghostty.logger.error("ghostty_config_new failed during reload")
            return nil
        }

        loadConfigIntoGhostty(
            config,
            presentationOverrides: presentationOverrides,
            refreshThemes: refreshThemes
        )
        ghostty_config_finalize(config)
        return config
    }

    private func cachedSurfaceConfig(for presentationOverrides: TerminalPresentationOverrides) -> ghostty_config_t? {
        let key = SurfaceConfigCacheKey(
            fontName: configuration.fontName,
            fontSize: presentationOverrides.fontSize ?? configuration.fontSize,
            themeName: appearanceSnapshot.activeTheme.name,
            cursorStyleRaw: configuration.cursorStyle.rawValue,
            cursorBlink: configuration.cursorBlink,
            optionAsAltModeRaw: configuration.optionAsAltMode.rawValue
        )

        if let cachedConfig = surfaceConfigCache[key] {
            return cachedConfig
        }

        guard let config = makeConfig(presentationOverrides: presentationOverrides, refreshThemes: false) else {
            return nil
        }

        surfaceConfigCache[key] = config
        return config
    }

    private func clearSurfaceConfigCache() {
        for config in surfaceConfigCache.values {
            ghostty_config_free(config)
        }
        surfaceConfigCache.removeAll()
    }

    private func removeReleasedSurfaceReferences() {
        activeSurfaces.removeAll { $0.terminalView == nil }
    }

    /// Generate and load config content into a ghostty_config_t
    private func loadConfigIntoGhostty(
        _ config: ghostty_config_t,
        presentationOverrides: TerminalPresentationOverrides = .empty,
        refreshThemes: Bool = true
    ) {
        // Create temp config directory and use Ghostty themes
        let tempDir = NSTemporaryDirectory()
        let ghosttyConfigDir = (tempDir as NSString).appendingPathComponent(".config/ghostty")
        let configFilePath = (ghosttyConfigDir as NSString).appendingPathComponent("config")
        let tempThemesDir = (ghosttyConfigDir as NSString).appendingPathComponent("themes")

        do {
            let themesDirectoryExists = FileManager.default.fileExists(atPath: tempThemesDir)
            try FileManager.default.createDirectory(atPath: ghosttyConfigDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: tempThemesDir, withIntermediateDirectories: true)

            if refreshThemes || !themesDirectoryExists {
                setupThemes(tempThemesDir: tempThemesDir)
            }

            // Detect shell for integration
            let shell = Foundation.ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = (shell as NSString).lastPathComponent

            // Create config with font settings, shell integration, and theme
            let effectiveFontSize = presentationOverrides.fontSize ?? configuration.fontSize
            let configContent = Ghostty.ConfigBuilder.configContent(
                primaryFontFamily: configuration.fontName,
                fontSize: effectiveFontSize,
                shellName: shellName,
                themeName: appearanceSnapshot.activeTheme.name,
                cursorStyle: configuration.cursorStyle,
                cursorBlink: configuration.cursorBlink,
                optionAsAltMode: configuration.optionAsAltMode,
                remoteClipboardReadPolicy: configuration.remoteClipboardReadPolicy
            )

            Ghostty.logger.info("Loading Ghostty theme: \(self.appearanceSnapshot.activeTheme.name)")

            try configContent.write(toFile: configFilePath, atomically: true, encoding: String.Encoding.utf8)

            // Set XDG_CONFIG_HOME to our temp directory
            // Ghostty will look for themes at XDG_CONFIG_HOME/ghostty/themes/
            setenv("XDG_CONFIG_HOME", (tempDir as NSString).appendingPathComponent(".config"), 1)

            // Load default files - will load our XDG config
            ghostty_config_load_default_files(config)

            Ghostty.logger.info("Loaded terminal settings - Font: \(self.configuration.fontName) \(Int(effectiveFontSize))pt, Theme: \(self.appearanceSnapshot.activeTheme.name)")
        } catch {
            Ghostty.logger.warning("Failed to write config: \(error)")
        }
    }

    /// Setup themes in temp directory - handles both structured and flattened bundle resources
    private func setupThemes(tempThemesDir: String) {
        guard let resourcePath = Bundle.main.resourcePath else { return }

        let fm = FileManager.default

        // Check if themes are in structured path (folder reference)
        let structuredThemesPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        if fm.fileExists(atPath: structuredThemesPath) {
            // Themes are structured - create symlink or copy
            copyThemesFromDirectory(structuredThemesPath, to: tempThemesDir)
            return
        }

        // Fallback: themes might be flattened in Resources root
        // Theme files have no extension and aren't known system files
        let knownNonThemes = Set(["Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty",
                                   "CodeSignature", "embedded", "_CodeSignature"])

        guard let files = try? fm.contentsOfDirectory(atPath: resourcePath) else { return }

        for file in files {
            let fullPath = (resourcePath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            // Skip directories, hidden files, files with extensions, and known non-themes
            guard !isDir.boolValue else { continue }
            guard !file.hasPrefix(".") else { continue }
            guard !file.contains(".") else { continue }
            guard !knownNonThemes.contains(file) else { continue }

            // This looks like a theme file - copy to temp themes dir
            let destPath = (tempThemesDir as NSString).appendingPathComponent(file)
            if !fm.fileExists(atPath: destPath) {
                try? fm.copyItem(atPath: fullPath, toPath: destPath)
            }
        }

        copyCustomThemes(to: tempThemesDir)
        Ghostty.logger.info("Copied themes from flattened resources to \(tempThemesDir)")
    }

    /// Copy themes from a directory to temp themes dir
    private func copyThemesFromDirectory(_ sourcePath: String, to destPath: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sourcePath) else { return }

        for file in files {
            guard !file.hasPrefix(".") else { continue }
            let src = (sourcePath as NSString).appendingPathComponent(file)
            let dst = (destPath as NSString).appendingPathComponent(file)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: src, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }

            if !fm.fileExists(atPath: dst) {
                try? fm.copyItem(atPath: src, toPath: dst)
            }
        }

        copyCustomThemes(to: destPath)
        Ghostty.logger.info("Copied themes from \(sourcePath) to \(destPath)")
    }

    private func copyCustomThemes(to tempThemesDir: String) {
        let fm = FileManager.default
        let customThemesDir = TerminalThemeStoragePaths.customThemesDirectoryPath()
        guard fm.fileExists(atPath: customThemesDir) else { return }
        guard let files = try? fm.contentsOfDirectory(atPath: customThemesDir) else { return }

        for file in files {
            guard !file.hasPrefix(".") else { continue }
            let src = (customThemesDir as NSString).appendingPathComponent(file)
            let dst = (tempThemesDir as NSString).appendingPathComponent(file)

            var isDir: ObjCBool = false
            fm.fileExists(atPath: src, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }

            guard let content = try? String(contentsOfFile: src, encoding: .utf8),
                  (try? TerminalThemeValidator.validateAndNormalizeThemeContent(content)) != nil else {
                if fm.fileExists(atPath: dst) {
                    try? fm.removeItem(atPath: dst)
                }
                continue
            }

            if fm.fileExists(atPath: dst) {
                try? fm.removeItem(atPath: dst)
            }
            try? fm.copyItem(atPath: src, toPath: dst)
        }
    }
}
