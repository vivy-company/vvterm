//
//  GhosttyRenderingSetup+iOS.swift
//  VVTerm
//

#if os(iOS)
import Metal
import OSLog
import UIKit

extension GhosttyRenderingSetup {
    // MARK: - Layer Setup

    /// On iOS, Ghostty handles all Metal layer configuration internally.
    /// It creates its own IOSurfaceLayer and adds it as a sublayer of the view's layer.
    /// We don't need to configure anything here.
    func setupLayer(for view: UIView) {
        // No-op: Ghostty creates its own IOSurfaceLayer as a sublayer
        // See Metal.zig: view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value})
        Self.logger.debug("iOS: Ghostty will configure Metal layer internally")
    }

    // MARK: - Surface Setup

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
        callbackContext: Ghostty.CallbackContext<GhosttyTerminalView>,
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
        surfaceConfig.userdata = callbackContext.userdata

        // Set scale factor for retina displays
        // Use contentScaleFactor which we set in GhosttyTerminalView.init to UIScreen.main.scale
        let scale = view.contentScaleFactor
        surfaceConfig.scale_factor = Double(scale)

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
        guard let cSurface = ghostty_surface_new(ghosttyApp, &surfaceConfig) else {
            Self.logger.error("ghostty_surface_new failed")
            return nil
        }

        // Set content scale BEFORE size (order matters - matches official Ghostty)
        ghostty_surface_set_content_scale(cSurface, scale, scale)

        // Then set size with scaled dimensions
        let initialSize = initialBounds.size.width > 0 ? initialBounds.size : CGSize(width: 800, height: 600)
        if let surfaceSize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: initialSize.width * scale,
            height: initialSize.height * scale
        ) {
            ghostty_surface_set_size(cSurface, surfaceSize.width, surfaceSize.height)
            Self.logger.info("Ghostty surface created - scale: \(scale), size: \(surfaceSize.width)x\(surfaceSize.height)")
        } else {
            Self.logger.error("Ghostty surface created without a valid initial size")
        }

        return cSurface
    }

    // MARK: - Scale and Size Updates

    /// On iOS, layout is handled by GhosttyTerminalView.sizeDidChange which follows
    /// the official Ghostty pattern. This method is provided for compatibility but
    /// the view should call sizeDidChange directly.
    func updateLayout(view: UIView, metalLayer: CAMetalLayer?, surface: ghostty_surface_t?, lastSize: inout CGSize) -> Bool {
        // On iOS, Ghostty manages its own IOSurfaceLayer as a sublayer.
        // Size updates should be done via sizeDidChange in GhosttyTerminalView.
        // This is a no-op for compatibility with code that still calls it.
        return surface != nil && view.bounds.width > 0 && view.bounds.height > 0
    }
}
#endif
