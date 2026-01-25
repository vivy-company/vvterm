//
//  GhosttyRenderingSetup.swift
//  VVTerm
//
//  Handles Metal layer setup and rendering configuration for Ghostty terminal
//

import Metal
import OSLog
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Manages Metal rendering setup and configuration for Ghostty terminal
@MainActor
class GhosttyRenderingSetup {
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyRendering")

    // MARK: - Terminal Settings from AppStorage

    @AppStorage("terminalFontName") private var terminalFontName = "JetBrainsMono Nerd Font"
    @AppStorage("terminalFontSize") private var terminalFontSize = 8.0
    @AppStorage("terminalBackgroundColor") private var terminalBackgroundColor = "#1e1e2e"
    @AppStorage("terminalForegroundColor") private var terminalForegroundColor = "#cdd6f4"
    @AppStorage("terminalCursorColor") private var terminalCursorColor = "#f5e0dc"
    @AppStorage("terminalSelectionBackground") private var terminalSelectionBackground = "#585b70"
    @AppStorage("terminalPalette") private var terminalPalette = "#45475a,#f38ba8,#a6e3a1,#f9e2af,#89b4fa,#f5c2e7,#94e2d5,#a6adc8,#585b70,#f37799,#89d88b,#ebd391,#74a8fc,#f2aede,#6bd7ca,#bac2de"

    // MARK: - Layer Setup

    #if os(macOS)
    /// Configure the Metal-backed layer for terminal rendering (macOS)
    ///
    /// CRITICAL: Must set layer property BEFORE setting wantsLayer = true
    /// This ensures Metal rendering works correctly
    func setupLayer(for view: NSView) {
        // Create Metal layer
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // IMPORTANT: Set layer before wantsLayer for proper Metal initialization
        view.layer = metalLayer
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .duringViewResize

        Self.logger.debug("Metal layer configured")
    }
    #else
    /// On iOS, Ghostty handles all Metal layer configuration internally.
    /// It creates its own IOSurfaceLayer and adds it as a sublayer of the view's layer.
    /// We don't need to configure anything here.
    func setupLayer(for view: UIView) {
        // No-op: Ghostty creates its own IOSurfaceLayer as a sublayer
        // See Metal.zig: view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value})
        Self.logger.debug("iOS: Ghostty will configure Metal layer internally")
    }
    #endif

    // MARK: - Surface Setup

    #if os(macOS)
    /// Create and configure the Ghostty surface (macOS)
    ///
    /// - Parameters:
    ///   - view: The NSView to render into
    ///   - ghosttyApp: The Ghostty app handle
    ///   - worktreePath: Working directory path
    ///   - initialBounds: Initial view bounds
    ///   - window: The containing window
    ///   - paneId: Optional pane identifier
    ///   - command: Optional command to execute
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    func setupSurface(
        view: NSView,
        ghosttyApp: ghostty_app_t,
        worktreePath: String,
        initialBounds: NSRect,
        window: NSWindow?,
        paneId: String? = nil,
        command: String? = nil,
        useCustomIO: Bool = false
    ) -> ghostty_surface_t? {
        // Configure surface with working directory
        var surfaceConfig = ghostty_surface_config_new()

        // CRITICAL: Set platform information
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()

        // Set userdata
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()

        // Set scale factor for retina displays
        surfaceConfig.scale_factor = Double(window?.backingScaleFactor ?? 2.0)

        // Set font size from settings
        surfaceConfig.font_size = Float(terminalFontSize)

        // Enable custom I/O backend for SSH clients
        surfaceConfig.use_custom_io = useCustomIO

        // Set working directory
        var workingDirPtr: UnsafeMutablePointer<CChar>?
        var commandPtr: UnsafeMutablePointer<CChar>?

        if let workingDir = strdup(worktreePath) {
            workingDirPtr = workingDir
            surfaceConfig.working_directory = UnsafePointer(workingDir)
        }

        // Set command if provided (only relevant when not using custom I/O)
        if !useCustomIO, let command = command, !command.isEmpty {
            if let cmd = strdup(command) {
                commandPtr = cmd
                surfaceConfig.command = UnsafePointer(cmd)
                Self.logger.info("Setting command: \(command)")
            }
        }

        defer {
            if let wd = workingDirPtr {
                free(wd)
            }
            if let cmd = commandPtr {
                free(cmd)
            }
        }

        // Create the surface
        // NOTE: subprocess spawns during ghostty_surface_new, so size warnings may appear
        // if view frame isn't set yet - this is unavoidable with current API
        guard let cSurface = ghostty_surface_new(ghosttyApp, &surfaceConfig) else {
            Self.logger.error("ghostty_surface_new failed")
            return nil
        }

        // Immediately set size after creation to minimize "small grid" warnings
        let scaledSize = view.convertToBacking(initialBounds.size.width > 0 ? initialBounds.size : NSSize(width: 800, height: 600))
        ghostty_surface_set_size(
            cSurface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )

        // Set content scale for retina displays
        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_content_scale(cSurface, scale, scale)

        Self.logger.info("Ghostty surface created at: \(worktreePath)")

        return cSurface
    }
    #else
    /// Create and configure the Ghostty surface (iOS)
    ///
    /// - Parameters:
    ///   - view: The UIView to render into
    ///   - ghosttyApp: The Ghostty app handle
    ///   - worktreePath: Working directory path
    ///   - initialBounds: Initial view bounds
    ///   - paneId: Optional pane identifier
    ///   - command: Optional command to execute
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    func setupSurface(
        view: UIView,
        ghosttyApp: ghostty_app_t,
        worktreePath: String,
        initialBounds: CGRect,
        paneId: String? = nil,
        command: String? = nil,
        useCustomIO: Bool = false
    ) -> ghostty_surface_t? {
        // Configure surface with working directory
        var surfaceConfig = ghostty_surface_config_new()

        // CRITICAL: Set platform information for iOS
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform.ios.uiview = Unmanaged.passUnretained(view).toOpaque()

        // Set userdata
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()

        // Set scale factor for retina displays
        // Use contentScaleFactor which we set in GhosttyTerminalView.init to UIScreen.main.scale
        let scale = view.contentScaleFactor
        surfaceConfig.scale_factor = Double(scale)

        // Set font size from settings
        surfaceConfig.font_size = Float(terminalFontSize)

        // Enable custom I/O backend for SSH clients
        surfaceConfig.use_custom_io = useCustomIO

        // Set working directory
        var workingDirPtr: UnsafeMutablePointer<CChar>?
        var commandPtr: UnsafeMutablePointer<CChar>?

        if let workingDir = strdup(worktreePath) {
            workingDirPtr = workingDir
            surfaceConfig.working_directory = UnsafePointer(workingDir)
        }

        // Set command if provided (only relevant when not using custom I/O)
        if !useCustomIO, let command = command, !command.isEmpty {
            if let cmd = strdup(command) {
                commandPtr = cmd
                surfaceConfig.command = UnsafePointer(cmd)
                Self.logger.info("Setting command: \(command)")
            }
        }

        defer {
            if let wd = workingDirPtr {
                free(wd)
            }
            if let cmd = commandPtr {
                free(cmd)
            }
        }

        // Create the surface
        guard let cSurface = ghostty_surface_new(ghosttyApp, &surfaceConfig) else {
            Self.logger.error("ghostty_surface_new failed")
            return nil
        }

        // Set content scale BEFORE size (order matters - matches official Ghostty)
        ghostty_surface_set_content_scale(cSurface, scale, scale)

        // Then set size with scaled dimensions
        let initialSize = initialBounds.size.width > 0 ? initialBounds.size : CGSize(width: 800, height: 600)
        let scaledWidth = UInt32(initialSize.width * scale)
        let scaledHeight = UInt32(initialSize.height * scale)
        ghostty_surface_set_size(cSurface, scaledWidth, scaledHeight)

        Self.logger.info("Ghostty surface created - scale: \(scale), size: \(scaledWidth)x\(scaledHeight)")

        return cSurface
    }
    #endif

    // MARK: - Appearance Observation

    #if os(macOS)
    /// Setup observation for system appearance changes (light/dark mode) - macOS
    /// Implementation copied from Ghostty's SurfaceView_AppKit.swift
    func setupAppearanceObservation(for view: NSView, surface: Ghostty.Surface?) -> NSKeyValueObservation? {
        return view.observe(\.effectiveAppearance, options: [.new, .initial]) { view, change in
            guard let appearance = change.newValue else { return }
            guard let surface = surface?.unsafeCValue else { return }

            let scheme: ghostty_color_scheme_e
            switch (appearance.name) {
            case .aqua, .vibrantLight:
                scheme = GHOSTTY_COLOR_SCHEME_LIGHT

            case .darkAqua, .vibrantDark:
                scheme = GHOSTTY_COLOR_SCHEME_DARK

            default:
                scheme = GHOSTTY_COLOR_SCHEME_DARK
            }

            ghostty_surface_set_color_scheme(surface, scheme)
            Self.logger.debug("Color scheme updated to: \(scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light")")
        }
    }
    #endif

    // MARK: - Scale and Size Updates

    #if os(macOS)
    /// Update Metal layer content scale and surface scale factors (macOS)
    func updateBackingProperties(view: NSView, surface: ghostty_surface_t?, window: NSWindow?) {
        guard let surface = surface else { return }

        // Update Metal layer content scale
        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        // Update surface scale factors
        let fbFrame = view.convertToBacking(view.frame)
        let xScale = fbFrame.size.width / view.frame.size.width
        let yScale = fbFrame.size.height / view.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        // Update surface size (framebuffer dimensions changed)
        ghostty_surface_set_size(
            surface,
            UInt32(fbFrame.size.width),
            UInt32(fbFrame.size.height)
        )
    }

    /// Update Metal layer frame and Ghostty surface size (macOS)
    func updateLayout(view: NSView, metalLayer: CAMetalLayer?, surface: ghostty_surface_t?, lastSize: inout CGSize) -> Bool {
        // Update Metal layer frame to match view bounds
        if let metalLayer = metalLayer {
            metalLayer.frame = view.bounds
        }

        // Update Ghostty surface size during layout pass
        // Only update if backing pixel size actually changed to prevent flicker
        guard let surface = surface else { return false }
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return false }

        var scaledSize = view.convertToBacking(view.bounds.size)
        scaledSize = snapSizeToCell(surface: surface, scaledSize: scaledSize)

        // Only update if size changed by at least 1 pixel
        let widthChanged = abs(scaledSize.width - lastSize.width) >= 1.0
        let heightChanged = abs(scaledSize.height - lastSize.height) >= 1.0

        guard widthChanged || heightChanged else { return false }

        lastSize = scaledSize
        if let metalLayer = metalLayer {
            metalLayer.drawableSize = scaledSize
        }
        ghostty_surface_set_size(
            surface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )
        ghostty_surface_refresh(surface)

        return true
    }
    #else
    /// On iOS, layout is handled by GhosttyTerminalView.sizeDidChange which follows
    /// the official Ghostty pattern. This method is provided for compatibility but
    /// the view should call sizeDidChange directly.
    func updateLayout(view: UIView, metalLayer: CAMetalLayer?, surface: ghostty_surface_t?, lastSize: inout CGSize) -> Bool {
        // On iOS, Ghostty manages its own IOSurfaceLayer as a sublayer.
        // Size updates should be done via sizeDidChange in GhosttyTerminalView.
        // This is a no-op for compatibility with code that still calls it.
        return surface != nil && view.bounds.width > 0 && view.bounds.height > 0
    }
    #endif

    /// Snap the desired pixel size down to the nearest full terminal cell to avoid partial-cell artifacts.
    /// Snap size to whole pixels (scaledSize is already in pixel units).
    func snapSizeToCell(surface: ghostty_surface_t, scaledSize: CGSize) -> CGSize {
        CGSize(width: floor(scaledSize.width), height: floor(scaledSize.height))
    }
}
