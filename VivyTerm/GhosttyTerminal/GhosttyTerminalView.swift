//
//  GhosttyTerminalView.swift
//  aizen
//
//  Platform view subclass that integrates Ghostty terminal rendering
//

import Metal
import OSLog
import SwiftUI
import IOSurface

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
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

    // MARK: - Handler Components

    private var imeHandler: GhosttyIMEHandler!
    private var inputHandler: GhosttyInputHandler!
    private let renderingSetup = GhosttyRenderingSetup()

    /// Observation for appearance changes
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Rendering Control (no-op on macOS)

    /// iOS pauses rendering when views are offscreen. On macOS rendering is
    /// event-driven, so these are intentionally no-ops for API parity.
    func pauseRendering() {
    }

    func resumeRendering() {
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
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
        // Single refresh when view moves to window
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.forceRefresh()
            }
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
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed_data(surface, ptr, buffer.count)
        }
        // Trigger redraw after feeding data
        ghosttyAppWrapper?.appTick()
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
            DispatchQueue.main.async {
                view.writeCallback?(swiftData)
            }
        }, userdata)
    }

    /// Send text to the terminal (used by voice input)
    func sendText(_ text: String) {
        surface?.sendText(text)
        ghosttyAppWrapper?.appTick()
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard let surface = surface else { return }

        let escapeSequence: String
        switch key {
        case .escape:
            escapeSequence = "\u{1B}"
        case .tab:
            escapeSequence = "\t"
        case .enter:
            escapeSequence = "\r"
        case .backspace:
            escapeSequence = "\u{7F}"
        case .delete:
            escapeSequence = "\u{1B}[3~"
        case .arrowUp:
            escapeSequence = "\u{1B}[A"
        case .arrowDown:
            escapeSequence = "\u{1B}[B"
        case .arrowLeft:
            escapeSequence = "\u{1B}[D"
        case .arrowRight:
            escapeSequence = "\u{1B}[C"
        case .home:
            escapeSequence = "\u{1B}[H"
        case .end:
            escapeSequence = "\u{1B}[F"
        case .pageUp:
            escapeSequence = "\u{1B}[5~"
        case .pageDown:
            escapeSequence = "\u{1B}[6~"
        }

        surface.sendText(escapeSequence)
        ghosttyAppWrapper?.appTick()
    }

    /// Send a control key combination (Ctrl+C, Ctrl+D, etc.)
    func sendControlKey(_ char: Character) {
        guard let surface = surface else { return }

        // Control characters are char - 64 for A-Z (A=1, B=2, ..., Z=26)
        let asciiValue = char.uppercased().first?.asciiValue ?? 0
        if asciiValue >= 65 && asciiValue <= 90 {
            let controlChar = Character(UnicodeScalar(asciiValue - 64))
            surface.sendText(String(controlChar))
            ghosttyAppWrapper?.appTick()
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

#else
// MARK: - iOS Implementation

/// UIView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering (Ghostty handles this internally)
/// - Touch and keyboard input
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: UIView {
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

    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?
    private var didSignalReady = false

    /// Prevent rendering when the view is offscreen or being torn down.
    private var isShuttingDown = false
    private var isPaused = false
    private var displayLink: CADisplayLink?
    private var needsRender = false

    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm", category: "GhosttyTerminal")

    private var isSelecting = false
    private lazy var selectionRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSelectionPress(_:))
        )
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    // MARK: - Rendering Components

    private let renderingSetup = GhosttyRenderingSetup()

    private func requestRender() {
        guard !isShuttingDown else { return }
        guard !isPaused else { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        needsRender = true
        if displayLink == nil {
            performRender(surface: surface)
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick() {
        guard needsRender, let surface = surface?.unsafeCValue else { return }
        performRender(surface: surface)
    }

    private func performRender(surface: ghostty_surface_t) {
        needsRender = false
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        ghosttyAppWrapper?.appTick()
    }

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane
    ///   - command: Optional command to run instead of default shell
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(frame: CGRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App? = nil, paneId: String? = nil, command: String? = nil, useCustomIO: Bool = false) {
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command
        self.useCustomIO = useCustomIO

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : CGRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)

        // Set content scale factor for retina rendering (important before surface creation)
        self.contentScaleFactor = UIScreen.main.scale

        setupSurface()
        addGestureRecognizer(selectionRecognizer)
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        let wrapper = self.ghosttyAppWrapper
        let ref = self.surfaceReference
        if let wrapper = wrapper, let ref = ref {
            Task { @MainActor in
                wrapper.unregisterSurface(ref)
            }
        }
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this in dismantleUIView to ensure proper cleanup.
    func cleanup() {
        isShuttingDown = true
        isPaused = true
        stopDisplayLink()

        // Clear all callbacks first to prevent any further interactions
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onProgressReport = nil
        writeCallback = nil

        // Stop rendering/input callbacks and mark as occluded
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_write_callback(surface, nil, nil)
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_set_occlusion(surface, true)
        }

        // Unregister surface from app wrapper synchronously
        if let wrapper = ghosttyAppWrapper, let ref = surfaceReference {
            wrapper.unregisterSurface(ref)
        }

        // Clear surface reference to stop any further operations
        surface = nil
        surfaceReference = nil
    }

    /// Pause rendering and input without destroying the surface.
    func pauseRendering() {
        guard !isShuttingDown else { return }
        isPaused = true
        stopDisplayLink()

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_set_occlusion(surface, true)
        }
    }

    /// Resume rendering/input after a pause.
    func resumeRendering() {
        guard !isShuttingDown else { return }
        isPaused = false
        startDisplayLink()

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, false)
        }
    }

    // MARK: - Layer Type
    // On iOS, Ghostty adds its own IOSurfaceLayer as a sublayer of the view's
    // existing CALayer. Keep the default layer type to avoid CAMetalLayer
    // interfering with sublayer rendering/compositing.

    // MARK: - Setup

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
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            return
        }

        // CRITICAL: Configure the IOSurfaceLayer that Ghostty just added as a sublayer.
        // Ghostty's Metal renderer on iOS adds IOSurfaceLayer as a sublayer but doesn't
        // set its frame/contentsScale - we must do it here immediately after creation.
        // Without this, setSurfaceCallback will discard all frames due to size mismatch.
        let scale = self.contentScaleFactor
        if let sublayers = layer.sublayers {
            let ioLayers = sublayers.filter { String(describing: type(of: $0)) == "IOSurfaceLayer" }
            for sublayer in ioLayers {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sublayer.frame = bounds
                sublayer.contentsScale = scale
                CATransaction.commit()
            }
        }

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface)

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface)
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
        guard !isShuttingDown else { return }
        guard !isPaused else { return }
        guard window != nil else { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard size.width > 0 && size.height > 0 else { return }

        let scale = self.contentScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(size.width * scale),
            UInt32(size.height * scale)
        )

        // CRITICAL: iOS has no CADisplayLink - explicitly trigger rendering
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)

        if !didSignalReady {
            didSignalReady = true

            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }
    }

    // MARK: - UIView Overrides

    override var canBecomeFirstResponder: Bool {
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

    override func layoutSubviews() {
        super.layoutSubviews()

        guard !isShuttingDown else { return }
        guard !isPaused else { return }
        guard window != nil else { return }

        let scale = self.contentScaleFactor

        // CRITICAL: On iOS, Ghostty adds IOSurfaceLayer as a SUBLAYER (not replacing the view's layer).
        // Sublayers do NOT auto-resize with the parent - we MUST set their frame AND contentsScale.
        // Ghostty's setSurfaceCallback validates: layer.bounds * contentsScale == surface.dimensions
        // If bounds or scale are wrong, frames are silently discarded.
        if let sublayers = layer.sublayers {
            let ioLayers = sublayers.filter { String(describing: type(of: $0)) == "IOSurfaceLayer" }
            for (i, sublayer) in ioLayers.enumerated() {
                // Set frame AND contentsScale BEFORE calling sizeDidChange so bounds are correct when Ghostty renders
                // Use CATransaction to ensure immediate effect
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sublayer.frame = bounds
                sublayer.contentsScale = scale  // CRITICAL: Must match view's contentScaleFactor
                CATransaction.commit()
            }
        }

        // Now tell Ghostty the new size - it will render to the correctly-sized layer
        sizeDidChange(bounds.size)

    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let isVisible = (window != nil)
        isPaused = !isVisible
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, !isVisible)
        }

        if isVisible {
            // Ensure sublayer is configured before calling sizeDidChange
            // This handles the case where window assignment happens after init
            let scale = self.contentScaleFactor
            if let sublayers = layer.sublayers {
                let ioLayers = sublayers.filter { String(describing: type(of: $0)) == "IOSurfaceLayer" }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for sublayer in ioLayers {
                    sublayer.frame = bounds
                    sublayer.contentsScale = scale
                }
                CATransaction.commit()
            }
            sizeDidChange(frame.size)
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // Update color scheme when appearance changes
        guard let surface = surface?.unsafeCValue else { return }
        let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        becomeFirstResponder()

        if isSelecting { return }
        guard let surface = surface, let touch = touches.first else { return }
        let location = ghosttyPoint(touch.location(in: self))

        // Send mouse press event
        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .press,
            button: .left,
            mods: []
        )
        surface.sendMouseButton(mouseEvent)

        // Send position
        let posEvent = Ghostty.Input.MousePosEvent(
            x: location.x,
            y: location.y,
            mods: []
        )
        surface.sendMousePos(posEvent)
        requestRender()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        if isSelecting { return }
        guard let surface = surface, let touch = touches.first else { return }
        let location = ghosttyPoint(touch.location(in: self))

        let posEvent = Ghostty.Input.MousePosEvent(
            x: location.x,
            y: location.y,
            mods: []
        )
        surface.sendMousePos(posEvent)
        requestRender()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)

        if isSelecting { return }
        guard let surface = surface else { return }
        let mouseEvent = Ghostty.Input.MouseButtonEvent(
            action: .release,
            button: .left,
            mods: []
        )
        surface.sendMouseButton(mouseEvent)
        requestRender()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func ghosttyPoint(_ location: CGPoint) -> CGPoint {
        // UIKit coordinates are top-left origin; Ghostty iOS expects the same.
        location
    }

    @objc private func handleSelectionPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)
        let mods: Ghostty.Input.Mods = .shift

        switch recognizer.state {
        case .began:
            isSelecting = true
            becomeFirstResponder()
            surface.sendMouseButton(.init(action: .press, button: .left, mods: mods))
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: mods))
            requestRender()
        case .changed:
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: mods))
            requestRender()
        case .ended, .cancelled, .failed:
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: mods))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: mods))
            isSelecting = false
            requestRender()
            showEditMenu(at: location)
        default:
            break
        }
    }

    private func showEditMenu(at location: CGPoint) {
        guard let cSurface = surface?.unsafeCValue else { return }
        guard ghostty_surface_has_selection(cSurface) else { return }
        let targetRect = CGRect(x: location.x, y: location.y, width: 1, height: 1)
        UIMenuController.shared.showMenu(from: self, rect: targetRect)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            guard let cSurface = surface?.unsafeCValue else { return false }
            return ghostty_surface_has_selection(cSurface)
        case #selector(paste(_:)):
            return true
        default:
            return false
        }
    }

    @objc override func copy(_ sender: Any?) {
        _ = surface?.perform(action: "copy_to_clipboard")
    }

    @objc override func paste(_ sender: Any?) {
        _ = surface?.perform(action: "paste_from_clipboard")
    }

    // MARK: - Software Keyboard (UIKeyInput)

    // MARK: - Keyboard Input (Hardware Keyboard)

    override var keyCommands: [UIKeyCommand]? {
        // Return nil to let the system handle key commands
        // Individual key handling is done via pressesBegan/pressesEnded
        return nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let surface = surface else {
            super.pressesBegan(presses, with: event)
            return
        }

        for press in presses {
            guard let key = press.key else { continue }

            // Convert UIKey to Ghostty key event
            if let keyEvent = Ghostty.Input.KeyEvent(uiKey: key, action: .press) {
                surface.sendKeyEvent(keyEvent)
            }
        }
        requestRender()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let surface = surface else {
            super.pressesEnded(presses, with: event)
            return
        }

        for press in presses {
            guard let key = press.key else { continue }

            if let keyEvent = Ghostty.Input.KeyEvent(uiKey: key, action: .release) {
                surface.sendKeyEvent(keyEvent)
            }
        }
        requestRender()
    }

    // MARK: - Text Input from Software Keyboard

    /// Send text to the terminal (called from keyboard toolbar or software keyboard)
    func sendText(_ text: String) {
        surface?.sendText(text)
        requestRender()
    }

    private func sendKeyPress(_ key: Ghostty.Input.Key) {
        guard let surface = surface else { return }
        surface.sendKeyEvent(.init(key: key, action: .press))
        surface.sendKeyEvent(.init(key: key, action: .release))
        requestRender()
    }

    private func sendControlByte(_ value: UInt8) {
        let scalar = UnicodeScalar(value)
        sendText(String(Character(scalar)))
    }

    private func sendTextKeyEvent(_ text: String) {
        guard let surface = surface else { return }
        let codepoint = text.unicodeScalars.first?.value ?? 0
        let press = Ghostty.Input.KeyEvent(
            key: .space,
            action: .press,
            text: text,
            composing: false,
            mods: [],
            consumedMods: [],
            unshiftedCodepoint: codepoint
        )
        surface.sendKeyEvent(press)
        let release = Ghostty.Input.KeyEvent(
            key: .space,
            action: .release,
            text: nil,
            composing: false,
            mods: [],
            consumedMods: [],
            unshiftedCodepoint: codepoint
        )
        surface.sendKeyEvent(release)
        requestRender()
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard let surface = surface else { return }

        let escapeSequence: String
        switch key {
        case .escape:
            escapeSequence = "\u{1B}"
        case .tab:
            escapeSequence = "\t"
        case .enter:
            sendControlByte(0x0D)
            return
        case .backspace:
            // DEL (0x7F) is the typical backspace for terminals.
            sendControlByte(0x7F)
            return
        case .arrowUp:
            escapeSequence = "\u{1B}[A"
        case .arrowDown:
            escapeSequence = "\u{1B}[B"
        case .arrowLeft:
            escapeSequence = "\u{1B}[D"
        case .arrowRight:
            escapeSequence = "\u{1B}[C"
        case .home:
            escapeSequence = "\u{1B}[H"
        case .end:
            escapeSequence = "\u{1B}[F"
        case .pageUp:
            escapeSequence = "\u{1B}[5~"
        case .pageDown:
            escapeSequence = "\u{1B}[6~"
        case .delete:
            escapeSequence = "\u{1B}[3~"
        }

        sendText(escapeSequence)
    }

    /// Send control key combination (e.g., Ctrl+C)
    func sendControlKey(_ char: Character) {
        guard let surface = surface else { return }

        // Control characters are char - 64 for A-Z (A=1, B=2, ..., Z=26)
        let asciiValue = char.uppercased().first?.asciiValue ?? 0
        if asciiValue >= 65 && asciiValue <= 90 {
            let controlChar = Character(UnicodeScalar(asciiValue - 64))
            sendText(String(controlChar))
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
    func forceRefresh() {
        guard !isShuttingDown else { return }
        guard !isPaused else { return }
        guard window != nil else { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        // Set scale and size
        let scale = self.contentScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))

        // CRITICAL: iOS has no CADisplayLink - explicitly trigger rendering
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
    }

    // MARK: - Custom I/O API (for SSH clients)

    /// Callback invoked when user types in the terminal
    var writeCallback: ((Data) -> Void)?

    /// Feed data from SSH channel to the terminal for rendering.
    func feedData(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }

        // Feed data to terminal
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed_data(surface, ptr, buffer.count)
        }

        ghosttyAppWrapper?.appTick()
        requestRender()
    }

    /// Setup the write callback to capture keyboard input
    func setupWriteCallback() {
        guard let surface = surface?.unsafeCValue else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_write_callback(surface, { userdata, data, len in
            guard let userdata = userdata else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            guard let data = data, len > 0 else { return }
            let swiftData = Data(bytes: data, count: len)
            DispatchQueue.main.async {
                view.writeCallback?(swiftData)
            }
        }, userdata)
    }

}

// MARK: - Software Keyboard (UIKeyInput)

extension GhosttyTerminalView: UIKeyInput, UITextInputTraits {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            sendKeyPress(.enter)
            return
        }
        if text == "\t" {
            sendKeyPress(.tab)
            return
        }

        // Normalize line endings for paste (convert to CR for terminals)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            sendText(normalized.replacingOccurrences(of: "\n", with: "\r"))
            return
        }

        if text.count == 1 {
            sendTextKeyEvent(text)
        } else {
            sendText(text)
        }
    }

    func deleteBackward() {
        sendKeyPress(.backspace)
    }

    var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set { }
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { }
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { }
    }

    var enablesReturnKeyAutomatically: Bool {
        get { false }
        set { }
    }

    var returnKeyType: UIReturnKeyType {
        get { .default }
        set { }
    }
}

#endif

/// Special keys that can be sent to the terminal
enum TerminalSpecialKey {
    case escape
    case tab
    case enter
    case backspace
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
    case delete
}
