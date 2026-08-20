//
//  GhosttyTerminalSurfaceLifecycle+macOS.swift
//  VVTerm
//
//  macOS Ghostty surface setup, rendering, geometry, and teardown.
//

#if os(macOS)
import AppKit
import OSLog
import QuartzCore

extension GhosttyTerminalView {
    /// iOS pauses rendering when views are offscreen. On macOS rendering is
    /// event-driven, so these are intentionally no-ops for API parity.
    func pauseRendering() {
    }

    func resumeRendering() {
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this when closing a session to ensure proper cleanup.
    func cleanup() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelClipboardConfirmations()
        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorHideWorkItem = nil

        // Stop display link first
        stopDisplayLink()

        // Remove config reload observer
        if let observer = configReloadObserver {
            NotificationCenter.default.removeObserver(observer)
            configReloadObserver = nil
        }
        appearanceObservation?.invalidate()
        appearanceObservation = nil

        // Clear all callbacks to break retain cycles
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onPwdChange = nil
        onProgressReport = nil
        onResize = nil
        onZoomAction = nil
        richPasteInterceptor = nil
        terminalContextMenuActions = nil
        writeCallback = nil

        // Stop rendering/input callbacks
        if let cSurface = surface?.unsafeCValue {
            ghostty_surface_set_write_callback(cSurface, nil, nil)
            ghostty_surface_set_focus(cSurface, false)
        }
        imeHandler.updateSurface(nil)
        inputHandler.updateSurface(nil)

        // Unregister surface from app wrapper synchronously
        if let wrapper = ghosttyAppWrapper, let ref = surfaceReference {
            wrapper.unregisterSurface(ref)
        }
        surfaceReference = nil

        // CRITICAL: Explicitly free the surface to release Metal resources
        // Do not rely on deinit - Task.detached may never run
        surface?.free()
        surface = nil
    }

    /// Configure the Metal-backed layer for terminal rendering
    func setupLayer() {
        renderingSetup.setupLayer(for: self)
    }

    /// Create and configure the Ghostty surface
    func setupSurface() {
        guard let app = ghosttyApp else {
            Self.logger.error("Cannot create surface: ghostty_app_t is nil")
            return
        }

        let callbackContext = Ghostty.CallbackContext(owner: self)
        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            callbackContext: callbackContext,
            worktreePath: worktreePath,
            initialBounds: bounds,
            window: window,
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            callbackContext.invalidate()
            return
        }

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(
            cSurface: cSurface,
            callbackContext: callbackContext
        )

        // Update handlers with surface
        imeHandler.updateSurface(self.surface)
        inputHandler.updateSurface(self.surface)

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface, terminalView: self)
        }
    }

    /// Setup observation for system appearance changes (light/dark mode)
    func setupAppearanceObservation() {
        appearanceObservation = renderingSetup.setupAppearanceObservation(for: self, surface: surface)
    }

    func setupFrameObservation() {
        // We rely on layout() + updateLayout to resize the surface.
        self.postsFrameChangedNotifications = false
    }

    func setupConfigReloadObservation() {
        configReloadObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRefresh()
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderingSetup.updateBackingProperties(view: self, surface: surface?.unsafeCValue, window: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Manage display link based on window attachment
        if window != nil {
            if useCustomIO, displayLink == nil {
                setupDisplayLink()
            }
            // Request render to start display link if needed
            DispatchQueue.main.async { [weak self] in
                self?.requestRender()
                self?.forceRefresh()
            }
        } else {
            // Stop display link when removed from window
            stopDisplayLink()
        }
    }

    var currentTerminalGridSize: (cols: Int, rows: Int)? {
        guard let size = terminalSize() else { return nil }
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    var currentTerminalPixelSize: TerminalPixelSize? {
        TerminalPixelSize(size: lastSurfaceSize)
    }

    // Override safe area insets to use full available space, including rounded corners
    // This matches Ghostty's SurfaceScrollView implementation
    override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsetsZero
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Force layout to be called to fix up subviews
        // This matches Ghostty's SurfaceScrollView.setFrameSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let didUpdate = renderingSetup.updateLayout(
            view: self,
            metalLayer: layer as? CAMetalLayer,
            surface: surface?.unsafeCValue,
            lastSize: &lastSurfaceSize
        )
        if didUpdate && !didSignalReady {
            didSignalReady = true
            onReady?()
        }
        updateZoomIndicatorLayout()

        // Check for terminal size changes and notify via callback (for SSH PTY resize)
        if didUpdate, let size = terminalSize() {
            let cols = Int(size.columns)
            let rows = Int(size.rows)
            if cols > 0, rows > 0 {
                onResize?(cols, rows)
            }
        }
    }

    // MARK: - Process Lifecycle

    /// Check if the terminal process has exited
    var processExited: Bool {
        guard let surface = surface?.unsafeCValue else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Check if closing this terminal needs confirmation
    var needsConfirmQuit: Bool {
        guard let surface = surface else { return false }
        return surface.needsConfirmQuit
    }

    /// Get current terminal grid size
    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        guard let surface = surface else { return nil }
        return surface.terminalSize()
    }

    /// Force the terminal surface to refresh/redraw
    /// Useful after tmux reattaches or when view becomes visible
    func forceRefresh() {
        guard let surface = surface?.unsafeCValue else { return }

        // Force a size update to trigger tmux redraw
        let scaledSize = convertToBacking(bounds.size)
        if let surfaceSize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: scaledSize.width,
            height: scaledSize.height
        ) {
            ghostty_surface_set_size(surface, surfaceSize.width, surfaceSize.height)
        }

        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)

        // Trigger app tick to process any pending updates
        ghosttyAppWrapper?.appTick()

        // Force Metal layer to redraw
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.setNeedsDisplay()
        }
        layer?.setNeedsDisplay()
        needsDisplay = true
        needsLayout = true
        displayIfNeeded()
    }

    func applyPresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides) {
        surfacePresentationOverrides = presentationOverrides

        guard let surface = surface?.unsafeCValue else { return }
        ghosttyAppWrapper?.updateSurfaceConfig(surface, presentationOverrides: presentationOverrides)
        forceRefresh()
    }

    /// Reset Ghostty's terminal state before binding a fresh remote shell to a reused surface.
    func resetTerminalForReconnect() {
        guard !isShuttingDown else { return }
        _ = surface?.perform(action: "reset")
        forceRefresh()
    }
}

#endif
