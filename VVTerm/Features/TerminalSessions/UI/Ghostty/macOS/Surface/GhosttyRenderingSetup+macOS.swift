//
//  GhosttyRenderingSetup+macOS.swift
//  VVTerm
//

#if os(macOS)
import AppKit
import Metal
import OSLog

extension GhosttyRenderingSetup {
    // MARK: - Layer Setup

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

    // MARK: - Surface Setup

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
        callbackContext: Ghostty.CallbackContext<GhosttyTerminalView>,
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
        surfaceConfig.userdata = callbackContext.userdata

        // Set scale factor for retina displays
        surfaceConfig.scale_factor = Double(window?.backingScaleFactor ?? 2.0)

        // Keep font_size at 0 so Ghostty inherits the injected app configuration.
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
        if let surfaceSize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: scaledSize.width,
            height: scaledSize.height
        ) {
            ghostty_surface_set_size(cSurface, surfaceSize.width, surfaceSize.height)
        }

        // Set content scale for retina displays
        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_content_scale(cSurface, scale, scale)

        Self.logger.info("Ghostty surface created at: \(worktreePath)")

        return cSurface
    }

    // MARK: - Appearance Observation

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

    // MARK: - Scale and Size Updates

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

        let fbFrame = view.convertToBacking(view.frame)
        guard let surfaceSize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: fbFrame.size.width,
            height: fbFrame.size.height
        ) else {
            return
        }

        // Update surface scale factors
        let xScale = fbFrame.size.width / view.frame.size.width
        let yScale = fbFrame.size.height / view.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        // Update surface size (framebuffer dimensions changed)
        ghostty_surface_set_size(surface, surfaceSize.width, surfaceSize.height)
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
        guard let surfaceSize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: scaledSize.width,
            height: scaledSize.height
        ) else {
            return false
        }

        lastSize = scaledSize
        if let metalLayer = metalLayer {
            metalLayer.drawableSize = scaledSize
        }
        ghostty_surface_set_size(surface, surfaceSize.width, surfaceSize.height)
        ghostty_surface_refresh(surface)

        return true
    }
}
#endif
