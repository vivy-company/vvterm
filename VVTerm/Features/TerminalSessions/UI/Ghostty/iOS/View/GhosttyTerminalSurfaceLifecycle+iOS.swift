//
//  GhosttyTerminalSurfaceLifecycle+iOS.swift
//  VVTerm
//
//  iOS Ghostty surface setup, drawing, and teardown.
//

#if os(iOS)
import OSLog
import UIKit

extension GhosttyTerminalView {
    func requestRender() {
        if isShuttingDown { return }
        if isPaused { return }
        guard surface?.unsafeCValue != nil else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        if usesNativeTouchSelection, nativeSelectionLifecycle.shouldRefreshSnapshot {
            refreshNativeSelectionSnapshot()
        }
        markIOSurfaceLayersForDisplay()
    }

    private func scheduleCustomIORedraw() {
        guard useCustomIO else { return }
        guard !customIORedrawScheduled else { return }
        customIORedrawScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.customIORedrawScheduled = false
            guard !self.isShuttingDown, !self.isPaused else { return }
            guard let surface = self.surface?.unsafeCValue else { return }
            guard self.bounds.width > 0 && self.bounds.height > 0 else { return }

            self.updateContentScaleIfNeeded()
            self.configureIOSurfaceLayers(size: self.bounds.size)
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            self.markIOSurfaceLayersForDisplay()
            self.notifyKeyboardAvoidanceCursorRectIfNeeded()
        }
    }

    func cleanup() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelClipboardConfirmations()
        cancelTrackedHardwareInput()
        isPaused = true
        stopMomentumScrolling()
        stopSelectionAutoscroll()
        zoomIndicatorHideWorkItem?.cancel()
        zoomIndicatorHideWorkItem = nil

        // Remove config reload observer
        if let observer = configReloadObserver {
            NotificationCenter.default.removeObserver(observer)
            configReloadObserver = nil
        }
        if let observer = inputModeObserver {
            NotificationCenter.default.removeObserver(observer)
            inputModeObserver = nil
        }
        removeHardwareKeyboardObservers()

        // Clear all callbacks first to prevent any further interactions
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onPwdChange = nil
        onProgressReport = nil
        onResize = nil
        onKeyboardAvoidanceCursorRectChange = nil
        onKeyboardAvoidanceAccessoryFrameChange = nil
        onZoomAction = nil
        onPaneKeyboardShortcut = nil
        keyboardAvoidancePreservedSurfaceSize = nil
        keyboardAvoidanceReferenceSurfaceSize = nil
        tracksKeyboardAvoidanceReferenceSize = false
        onWindowAttachmentChange = nil
        onTerminalDirectTouch = nil
        onKeyboardBrowseModeChange = nil
        onKeyboardAccessoryHideRequested = nil
        onFindNavigatorVisibilityChange = nil
        onVoiceButtonTapped = nil
        richPasteInterceptor = nil
        writeCallback = nil
        if let nativeTextInteraction {
            imeProxyTextView.removeInteraction(nativeTextInteraction)
            self.nativeTextInteraction = nil
        }
        imeProxyTextView.inputDelegate = nil
        imeProxyTextView.terminalOwner = nil
        _ = imeProxyTextView.resignFirstResponder()
        keyboardToolbar = nil
        if let nativeFindInteraction {
            if nativeFindInteraction.isFindNavigatorVisible {
                nativeFindInteraction.dismissFindNavigator()
            }
            removeInteraction(nativeFindInteraction)
            self.nativeFindInteraction = nil
        }
        nativeFindSession = nil
        nativeSelectionLongPressAnchor = nil
        nativeSelectionLifecycle.cancel()
        nativeSelectionSnapshot = .empty
        if let editMenuInteraction {
            editMenuInteraction.dismissMenu()
            removeInteraction(editMenuInteraction)
            self.editMenuInteraction = nil
        }
        terminalTitleEditor?.dismiss(animated: false)
        terminalTitleEditor = nil
        terminalContextMenuActions = nil

        // Stop rendering/input callbacks and mark the surface as not visible.
        if let cSurface = surface?.unsafeCValue {
            ghostty_surface_set_write_callback(cSurface, nil, nil)
            setSurfaceFocus(false)
            ghostty_surface_set_occlusion(cSurface, false)
        }

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

    /// Pause rendering and input without destroying the surface.
    var isRenderingPaused: Bool {
        isPaused
    }

    func pauseRendering(preservingForegroundKeyboardGrid: Bool = false) {
        guard !isShuttingDown else { return }
        cancelTrackedHardwareInput()
        if preservingForegroundKeyboardGrid {
            preservesForegroundKeyboardGrid = true
        }
        isPaused = true

        if let surface = surface?.unsafeCValue {
            setSurfaceFocus(false)
            ghostty_surface_set_occlusion(surface, false)
        }
    }

    /// Resume rendering/input after a pause.
    func resumeRendering() {
        guard !isShuttingDown else { return }
        isPaused = false

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, true)
            // Pausing explicitly clears Ghostty's focus without resigning the
            // UIKit text-input owner. Restore that live ownership on resume;
            // the native Find navigator keeps its own responder and must not
            // make the terminal report focus.
            setSurfaceFocus(isTerminalTextInputActive && !isFindNavigatorActive)
        }

        if preservesForegroundKeyboardGrid {
            // The software keyboard temporarily leaves the layout while the
            // app is backgrounded. Keep the last terminal grid until UIKit
            // restores its final foreground geometry instead of sending an
            // intermediate full-height PTY resize to an idle Mosh session.
            redrawPreservingSurfaceSize()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isPaused else { return }
                self.redrawPreservingSurfaceSize()
            }
        } else {
            sizeDidChange(bounds.size)
            requestRender()
        }
    }

    private func redrawPreservingSurfaceSize() {
        guard !isShuttingDown, !isPaused else { return }
        guard let surface = surface?.unsafeCValue else { return }
        let surfaceSize = renderedSurfaceSize
        guard surfaceSize.width > 0, surfaceSize.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: surfaceSize)
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        markIOSurfaceLayersForDisplay()
        requestRender()
    }

    func setSurfaceFocus(_ isFocused: Bool) {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_set_focus(surface, isFocused)
        #if DEBUG
        keyboardUITestSurfaceFocused = isFocused
        #endif
    }

    // MARK: - Setup

    /// Create and configure the Ghostty surface
    func setupConfigReloadObservation() {
        configReloadObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.requestRender()
            }
        }
    }

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
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            callbackContext.invalidate()
            return
        }

        // CRITICAL: Configure the IOSurfaceLayer that Ghostty just added as a sublayer.
        // Ghostty's Metal renderer on iOS adds IOSurfaceLayer as a sublayer but doesn't
        // set its frame/contentsScale - we must do it here immediately after creation.
        // Without this, setSurfaceCallback will discard all frames due to size mismatch.
        configureIOSurfaceLayers(size: bounds.size)

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(
            cSurface: cSurface,
            callbackContext: callbackContext
        )

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface, terminalView: self)
        }

        Self.logger.info("Ghostty surface created, sublayers: \(self.layer.sublayers?.count ?? 0)")
    }

    // MARK: - Size Change Handling (matches official Ghostty iOS pattern)

    /// Notify Ghostty of size changes. This method follows the official Ghostty iOS implementation.
    /// It sets content scale BEFORE size, using the contentScaleFactor.
    /// NOTE: On iOS, we must also configure the IOSurfaceLayer's frame/contentsScale in layoutSubviews
    /// and didMoveToWindow because Ghostty adds it as a sublayer that doesn't auto-resize.
    /// Without proper sublayer configuration, Ghostty's setSurfaceCallback will discard all frames.
    func sizeDidChange(_ size: CGSize) {
        if isShuttingDown { return }
        let currentSurfaceSize = renderedSurfaceSize
        guard TerminalSurfaceGeometryPolicy.update(
            renderingIsPaused: isPaused,
            preservesForegroundKeyboardGrid: preservesForegroundKeyboardGrid,
            currentSize: currentSurfaceSize,
            proposedSize: size
        ) == .apply else {
            return
        }
        preservesForegroundKeyboardGrid = false
        guard let surface = surface?.unsafeCValue else { return }
        let surfaceSize = keyboardAvoidancePreservedSurfaceSize ?? size
        updateContentScaleIfNeeded()
        let scale = self.contentScaleFactor
        guard let ghosttySize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: surfaceSize.width * scale,
            height: surfaceSize.height * scale
        ) else {
            return
        }

        configureIOSurfaceLayers(size: surfaceSize)

        let pixelSize = CGSize(
            width: CGFloat(ghosttySize.width),
            height: CGFloat(ghosttySize.height)
        )

        if tracksKeyboardAvoidanceReferenceSize {
            updateKeyboardAvoidanceReferenceSize(surfaceSize)
        }

        let sizeChanged = pixelSize != lastPixelSize || scale != lastContentScale
        if sizeChanged {
            lastPixelSize = pixelSize
            lastContentScale = scale

            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, ghosttySize.width, ghosttySize.height)
            reportGridResizeIfNeeded()
        }

        if !isPaused {
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            notifyKeyboardAvoidanceCursorRectIfNeeded()
            if usesNativeTouchSelection {
                refreshNativeSelectionSnapshot()
            }
            markIOSurfaceLayersForDisplay()
        }

        if !didSignalReady {
            didSignalReady = true
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }
    }

    func applyPresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides) {
        surfacePresentationOverrides = presentationOverrides

        guard let surface = surface?.unsafeCValue else { return }
        ghosttyAppWrapper?.updateSurfaceConfig(surface, presentationOverrides: presentationOverrides)
        lastPixelSize = .zero
        sizeDidChange(bounds.size)
        requestRender()
    }

    private func reportGridResizeIfNeeded() {
        guard let size = terminalSize() else { return }
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 0, rows > 0 else { return }
        lastReportedGrid = (cols, rows)
        #if DEBUG
        keyboardUITestGridResizeCount += 1
        #endif
        onResize?(cols, rows)
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
    func forceRefresh() {
        if isShuttingDown { return }
        if isPaused { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: bounds.size)

        // Set scale and size
        let scale = self.contentScaleFactor
        guard let ghosttySize = TerminalGeometryConversion.ghosttySurfaceSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        ) else {
            return
        }
        lastPixelSize = CGSize(
            width: CGFloat(ghosttySize.width),
            height: CGFloat(ghosttySize.height)
        )
        lastContentScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, ghosttySize.width, ghosttySize.height)
        if window != nil {
            ghostty_surface_set_occlusion(surface, true)
        }

        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        markIOSurfaceLayersForDisplay()
        requestRender()
    }

    /// Reset Ghostty's terminal state before binding a fresh remote shell to a reused surface.
    func resetTerminalForReconnect() {
        guard !isShuttingDown else { return }
        _ = surface?.perform(action: "reset")
        forceRefresh()
    }

    func updateReadonlyState(_ isReadonly: Bool) {
        readonly = isReadonly
    }

    private func configureIOSurfaceLayers() {
        configureIOSurfaceLayers(size: nil)
    }

    private func configureIOSurfaceLayers(size: CGSize?) {
        let scale = self.contentScaleFactor
        guard let sublayers = layer.sublayers else { return }
        let targetBounds = size.map { CGRect(origin: .zero, size: $0) } ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers {
            guard isGhosttySurfaceLayer(sublayer) else { continue }
            sublayer.frame = targetBounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func markIOSurfaceLayersForDisplay() {
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { sublayer in
            guard isGhosttySurfaceLayer(sublayer) else { return }
            sublayer.setNeedsDisplay()
        }
    }

    private func isGhosttySurfaceLayer(_ layer: CALayer) -> Bool {
        !subviews.contains { subview in
            subview.layer === layer
        }
    }

    private func updateContentScaleIfNeeded() {
        let targetScale = window?.screen.scale ?? max(traitCollection.displayScale, 1)
        if contentScaleFactor != targetScale {
            contentScaleFactor = targetScale
        }
    }

    // MARK: - Custom I/O API (for SSH clients)

    /// Feed data from SSH channel to the terminal for rendering.
    func feedData(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }

        // Feed data to terminal
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed_data(surface, ptr, buffer.count)
        }

        scheduleCustomIORedraw()
        requestRender()
    }

    /// Setup the write callback to capture keyboard input
    func setupWriteCallback() {
        guard let surface = surface?.unsafeCValue else { return }
        guard let userdata = ghostty_surface_userdata(surface) else { return }

        ghostty_surface_set_write_callback(
            surface,
            ghosttyTerminalWriteCallback,
            userdata
        )
    }

}

#endif
