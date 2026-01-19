//
//  GhosttyTerminalView+macOS.swift
//  VVTerm
//
//  macOS NSView implementation for Ghostty terminal rendering
//

#if os(macOS)
import AppKit
import Metal
import OSLog
import SwiftUI
import IOSurface
import QuartzCore

/// NSView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering
/// - Input forwarding (keyboard, mouse, scroll)
/// - Focus management
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: NSView {
    // MARK: - Properties

    private var ghosttyApp: ghostty_app_t?
    private weak var ghosttyAppWrapper: Ghostty.App?
    internal var surface: Ghostty.Surface?
    private var surfaceReference: Ghostty.SurfaceReference?
    private let worktreePath: String
    private let paneId: String?
    private let initialCommand: String?
    private let useCustomIO: Bool

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback invoked when the terminal reports working directory changes (OSC 7)
    var onPwdChange: ((String) -> Void)?

    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?

    /// Callback when terminal size changes (cols, rows) - used for SSH PTY resize
    var onResize: ((Int, Int) -> Void)?

    private var didSignalReady = false

    /// Cell size in points for row-to-pixel conversion (used by scroll view)
    var cellSize: NSSize = .zero

    /// Current scrollbar state from Ghostty core (used by scroll view)
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "win.aizen.app", category: "GhosttyTerminal")

    // MARK: - Display Link Rendering (event-driven for SSH)

    private var displayLink: CVDisplayLink?
    private var needsRender = false

    /// Idle detection for display link - stops after timeout to save CPU
    private var lastActivityTime: CFAbsoluteTime = 0
    private var idleCheckTimer: DispatchSourceTimer?
    private static let idleTimeout: CFTimeInterval = 0.1  // 100ms idle before stopping display link

    // MARK: - Handler Components

    private var imeHandler: GhosttyIMEHandler!
    private var inputHandler: GhosttyInputHandler!
    private let renderingSetup = GhosttyRenderingSetup()

    /// Observation for appearance changes
    private var appearanceObservation: NSKeyValueObservation?

    /// Observer for config reload notifications
    private var configReloadObserver: NSObjectProtocol?

    // MARK: - Rendering Control

    /// Flag to prevent operations during cleanup
    private var isShuttingDown = false

    /// iOS pauses rendering when views are offscreen. On macOS rendering is
    /// event-driven, so these are intentionally no-ops for API parity.
    func pauseRendering() {
    }

    func resumeRendering() {
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this when closing a session to ensure proper cleanup.
    func cleanup() {
        isShuttingDown = true

        // Stop display link first
        stopDisplayLink()

        // Remove config reload observer
        if let observer = configReloadObserver {
            NotificationCenter.default.removeObserver(observer)
            configReloadObserver = nil
        }

        // Clear all callbacks to break retain cycles
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onPwdChange = nil
        onProgressReport = nil
        onResize = nil
        writeCallback = nil

        // Stop rendering/input callbacks
        if let cSurface = surface?.unsafeCValue {
            ghostty_surface_set_write_callback(cSurface, nil, nil)
            ghostty_surface_set_focus(cSurface, false)
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

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane (used for tmux session persistence)
    ///   - command: Optional command to run instead of default shell
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(frame: NSRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App? = nil, paneId: String? = nil, command: String? = nil, useCustomIO: Bool = false) {
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command
        self.useCustomIO = useCustomIO

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : NSRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)

        // Initialize handlers before setup
        self.imeHandler = GhosttyIMEHandler(view: self, surface: nil)
        self.inputHandler = GhosttyInputHandler(view: self, surface: nil, imeHandler: self.imeHandler)

        setupLayer()
        setupSurface()
        setupTrackingArea()
        setupAppearanceObservation()
        setupFrameObservation()
        setupConfigReloadObservation()
        if useCustomIO {
            setupDisplayLink()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        // Stop display link immediately (CVDisplayLink operations are thread-safe)
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        // Release the retained weak reference to prevent memory leak
        displayLinkWeakRef?.release()

        // Surface cleanup happens via Surface's deinit
        // Note: Cannot access @MainActor properties in deinit
        // Tracking areas are automatically cleaned up by NSView
        // Appearance observation is automatically invalidated

        // Surface reference cleanup needs to happen on main actor
        // We capture the values before the Task to avoid capturing self
        let wrapper = self.ghosttyAppWrapper
        let ref = self.surfaceReference
        if let wrapper = wrapper, let ref = ref {
            Task { @MainActor in
                wrapper.unregisterSurface(ref)
            }
        }
    }

    // MARK: - Setup

    /// Configure the Metal-backed layer for terminal rendering
    private func setupLayer() {
        renderingSetup.setupLayer(for: self)
    }

    /// Create and configure the Ghostty surface
    private func setupSurface() {
        guard let app = ghosttyApp else {
            Self.logger.error("Cannot create surface: ghostty_app_t is nil")
            return
        }

        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            worktreePath: worktreePath,
            initialBounds: bounds,
            window: window,
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            return
        }

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface)

        // Update handlers with surface
        imeHandler.updateSurface(self.surface)
        inputHandler.updateSurface(self.surface)

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface)
        }
    }

    /// Setup mouse tracking area for the entire view
    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .activeAlways  // Track even when not focused
        ]

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    /// Setup observation for system appearance changes (light/dark mode)
    private func setupAppearanceObservation() {
        appearanceObservation = renderingSetup.setupAppearanceObservation(for: self, surface: surface)
    }

    private func setupFrameObservation() {
        // We rely on layout() + updateLayout to resize the surface.
        self.postsFrameChangedNotifications = false
    }

    private func setupConfigReloadObservation() {
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

    /// Weak reference retained by display link - must be released when display link stops
    private var displayLinkWeakRef: Unmanaged<Weak<GhosttyTerminalView>>?

    /// Setup CVDisplayLink for display-synchronized rendering (SSH mode only)
    /// Event-driven: starts on activity, stops after idle timeout to save CPU
    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        // Prevent capture of self in C callback by using a weak reference wrapper
        let weakSelf = Weak(self)
        let retainedRef = Unmanaged.passRetained(weakSelf)
        displayLinkWeakRef = retainedRef

        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let weak = Unmanaged<Weak<GhosttyTerminalView>>.fromOpaque(userInfo).takeUnretainedValue()
            guard let view = weak.value else { return kCVReturnSuccess }

            DispatchQueue.main.async {
                view.displayLinkTick()
            }
            return kCVReturnSuccess
        }, retainedRef.toOpaque())

        self.displayLink = displayLink
        // Don't start immediately - will start on first activity
        setupIdleCheckTimer()
    }

    /// Called by display link callback - checks if we should continue or go idle
    private func displayLinkTick() {
        guard !isShuttingDown else { return }

        // Check if we've been idle too long
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            // Stop display link to save CPU when idle
            if let link = displayLink, CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
            return
        }

        // Process any pending render
        if needsRender, let surface = surface?.unsafeCValue {
            needsRender = false
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }

        // Always tick for cursor blink when active
        ghosttyAppWrapper?.appTick()
    }

    /// Setup timer to periodically check for idle state
    private func setupIdleCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.idleTimeout, repeating: Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.checkIdleState()
        }
        timer.resume()
        idleCheckTimer = timer
    }

    /// Check if display link should be stopped due to idle
    private func checkIdleState() {
        guard !isShuttingDown else { return }
        guard let link = displayLink, CVDisplayLinkIsRunning(link) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            CVDisplayLinkStop(link)
        }
    }

    /// Request a render - starts display link if needed
    private func requestRender() {
        guard !isShuttingDown else { return }
        lastActivityTime = CFAbsoluteTimeGetCurrent()
        needsRender = true

        // Start display link if not running
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    /// Stop and release the display link, including the weak reference
    private func stopDisplayLink() {
        // Cancel idle check timer
        idleCheckTimer?.cancel()
        idleCheckTimer = nil

        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil

        // Release the retained weak reference to prevent memory leak
        displayLinkWeakRef?.release()
        displayLinkWeakRef = nil
    }

    // MARK: - NSView Overrides

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        // Recreate with current bounds
        setupTrackingArea()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderingSetup.updateBackingProperties(view: self, surface: surface?.unsafeCValue, window: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Manage display link based on window attachment
        if window != nil {
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

    // Track last size sent to Ghostty to avoid redundant updates
    private var lastSurfaceSize: CGSize = .zero

    // Track last terminal size (cols, rows) to detect changes for SSH resize
    private var lastTerminalSize: (cols: Int, rows: Int) = (0, 0)

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

        // Check for terminal size changes and notify via callback (for SSH PTY resize)
        if didUpdate, let size = terminalSize() {
            let cols = Int(size.columns)
            let rows = Int(size.rows)
            if cols != lastTerminalSize.cols || rows != lastTerminalSize.rows {
                lastTerminalSize = (cols, rows)
                onResize?(cols, rows)
            }
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        inputHandler.handleKeyDown(with: event) { [weak self] events in
            self?.interpretKeyEvents(events)
        }
    }

    override func keyUp(with event: NSEvent) {
        inputHandler.handleKeyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler.handleFlagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Override to suppress NSBeep when interpretKeyEvents encounters unhandled commands
        // Without this, keys like delete at beginning of line, cmd+c with no selection, etc. cause beeps
        // Terminal handles all input via Ghostty, so we silently ignore unhandled commands
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        inputHandler.handleMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler.handleMouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler.handleRightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        inputHandler.handleRightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputHandler.handleOtherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        inputHandler.handleOtherMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        inputHandler.handleMouseMoved(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        inputHandler.handleMouseEntered(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    override func mouseExited(with event: NSEvent) {
        inputHandler.handleMouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inputHandler.handleScrollWheel(with: event)
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
        ghostty_surface_set_size(
            surface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )

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

    // MARK: - Custom I/O API (for SSH clients)

    /// Callback invoked when user types in the terminal (keyboard input to send to SSH)
    var writeCallback: ((Data) -> Void)?

    /// Feed data from SSH channel to the terminal for rendering
    func feedData(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }

        // Feed data immediately - SSH read loop already batches appropriately
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed_data(surface, ptr, buffer.count)
        }

        // Request render via display link (event-driven, will auto-stop when idle)
        requestRender()
    }

    /// Setup the write callback to capture keyboard input
    /// Call this after the surface is created to start receiving input
    func setupWriteCallback() {
        guard let surface = surface?.unsafeCValue else { return }

        // Pass self as userdata - we'll use it to call the Swift callback
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_write_callback(surface, { userdata, data, len in
            guard let userdata = userdata else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            guard let data = data, len > 0 else { return }
            let swiftData = Data(bytes: data, count: len)
            // Call directly - Ghostty calls this from main thread, no queue hop needed
            view.writeCallback?(swiftData)
        }, userdata)
    }

    /// Send text to the terminal (used by voice input)
    func sendText(_ text: String) {
        surface?.sendText(text)
        requestRender()
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard let surface = surface else { return }
        let escapeSequence = TerminalSpecialKeySequence.escapeSequence(for: key)
        surface.sendText(escapeSequence)
        requestRender()
    }

    /// Send a control key combination (Ctrl+C, Ctrl+D, etc.)
    func sendControlKey(_ char: Character) {
        guard let surface = surface else { return }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            surface.sendText(String(controlChar))
            requestRender()
        }
    }
}

// MARK: - NSTextInputClient Implementation

/// NSTextInputClient protocol conformance for IME (Input Method Editor) support
extension GhosttyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        imeHandler.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        imeHandler.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    func unmarkText() {
        imeHandler.unmarkText()
    }

    func selectedRange() -> NSRange {
        return imeHandler.selectedRange()
    }

    func markedRange() -> NSRange {
        return imeHandler.markedRange()
    }

    func hasMarkedText() -> Bool {
        return imeHandler.hasMarkedText
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return imeHandler.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return imeHandler.validAttributesForMarkedText()
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return imeHandler.firstRect(
            forCharacterRange: range,
            actualRange: actualRange,
            viewFrame: frame,
            window: window,
            surface: surface?.unsafeCValue
        )
    }

    func characterIndex(for point: NSPoint) -> Int {
        return imeHandler.characterIndex(for: point)
    }
}

// MARK: - Weak Reference Wrapper for CVDisplayLink callback

/// Thread-safe weak reference wrapper for use in C callbacks
private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}

#endif
