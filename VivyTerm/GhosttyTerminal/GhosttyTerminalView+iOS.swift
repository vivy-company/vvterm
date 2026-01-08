//
//  GhosttyTerminalView+iOS.swift
//  VivyTerm
//
//  iOS UIView implementation for Ghostty terminal rendering
//

#if os(iOS)
import UIKit
import Metal
import OSLog
import SwiftUI
import IOSurface

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

    /// Idle detection for display link - stops after timeout to save CPU
    private var lastActivityTime: CFAbsoluteTime = 0
    private static let idleTimeout: CFTimeInterval = 0.1  // 100ms idle before stopping display link

    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm", category: "GhosttyTerminal")

    private var isSelecting = false
    private var isScrolling = false
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

    private lazy var scrollRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGesture(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    /// Observer for config reload notifications
    private var configReloadObserver: NSObjectProtocol?

    // MARK: - Rendering Components

    private let renderingSetup = GhosttyRenderingSetup()

    private func requestRender() {
        guard !isShuttingDown else { return }
        guard !isPaused else { return }
        guard surface?.unsafeCValue != nil else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        lastActivityTime = CFAbsoluteTimeGetCurrent()
        needsRender = true

        // Start display link if not running
        if displayLink == nil {
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        Self.logger.debug("Display link started (activity)")
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick() {
        guard !isShuttingDown, !isPaused else { return }

        // Check if we've been idle too long
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            stopDisplayLink()
            Self.logger.debug("Display link stopped (idle)")
            return
        }

        // Only render if needed
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

        // Setup gesture recognizers with delegate for simultaneous recognition
        selectionRecognizer.delegate = self
        scrollRecognizer.delegate = self
        addGestureRecognizer(selectionRecognizer)
        addGestureRecognizer(scrollRecognizer)
        isUserInteractionEnabled = true

        setupConfigReloadObservation()
        registerColorSchemeObserver()
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

        // Remove config reload observer
        if let observer = configReloadObserver {
            NotificationCenter.default.removeObserver(observer)
            configReloadObserver = nil
        }

        // Clear all callbacks first to prevent any further interactions
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onProgressReport = nil
        writeCallback = nil

        // Stop rendering/input callbacks and mark as occluded
        if let cSurface = surface?.unsafeCValue {
            ghostty_surface_set_write_callback(cSurface, nil, nil)
            ghostty_surface_set_focus(cSurface, false)
            ghostty_surface_set_occlusion(cSurface, true)
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

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, false)
        }

        // Request a render to restart display link if needed
        requestRender()
    }

    // MARK: - Layer Type
    // On iOS, Ghostty adds its own IOSurfaceLayer as a sublayer of the view's
    // existing CALayer. Keep the default layer type to avoid CAMetalLayer
    // interfering with sublayer rendering/compositing.

    // MARK: - Setup

    /// Create and configure the Ghostty surface
    private func setupConfigReloadObservation() {
        configReloadObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.needsRender = true
            }
        }
    }

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
            for sublayer in ioLayers {
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
            // Note: becomeFirstResponder is now handled by SSHTerminalWrapper.updateUIView
            // based on isActive flag to avoid keyboard showing when terminal is hidden
            // Request render to start display link if needed (event-driven)
            requestRender()
        } else {
            stopDisplayLink()
        }
    }

    // Use trait change registration API (iOS 17+) with fallback
    private func registerColorSchemeObserver() {
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (view: GhosttyTerminalView, _: UITraitCollection) in
                self?.updateColorScheme()
            }
        }
    }

    private func updateColorScheme() {
        guard let surface = surface?.unsafeCValue else { return }
        let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // Tap just focuses keyboard - no mouse events (avoids accidental selection)
        _ = becomeFirstResponder()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        // Pan gesture handles scrolling, long press handles selection
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
    }

    private func ghosttyPoint(_ location: CGPoint) -> CGPoint {
        // UIKit coordinates are top-left origin; Ghostty iOS expects the same.
        location
    }

    // MARK: - Scroll Gesture

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let surface = surface else { return }
        if isSelecting { return }

        let translation = recognizer.translation(in: self)

        switch recognizer.state {
        case .began:
            isScrolling = true
        case .changed:
            // Send scroll delta directly (like macOS trackpad)
            // Multiply by 2 for better scroll speed (matches macOS precision multiplier)
            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: Double(translation.x) * 2,
                y: Double(translation.y) * 2,
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .changed)
            )
            surface.sendMouseScroll(scrollEvent)
            requestRender()

            // Reset translation so we get delta on next call
            recognizer.setTranslation(.zero, in: self)
        case .ended:
            isScrolling = false
            // Send momentum end
            let endEvent = Ghostty.Input.MouseScrollEvent(
                x: 0,
                y: 0,
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .ended)
            )
            surface.sendMouseScroll(endEvent)
        case .cancelled, .failed:
            isScrolling = false
        default:
            break
        }
    }

    @objc private func handleSelectionPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)
        let mods: Ghostty.Input.Mods = .shift

        switch recognizer.state {
        case .began:
            isSelecting = true
            _ = becomeFirstResponder()
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
        guard surface != nil else { return }

        switch key {
        case .enter:
            sendControlByte(0x0D)
            return
        case .backspace:
            // DEL (0x7F) is the typical backspace for terminals.
            sendControlByte(0x7F)
            return
        default:
            break
        }

        let escapeSequence = TerminalSpecialKeySequence.escapeSequence(for: key)
        sendText(escapeSequence)
    }

    /// Send control key combination (e.g., Ctrl+C)
    func sendControlKey(_ char: Character) {
        guard surface != nil else { return }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
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
            // Call directly - Ghostty calls this from main thread, no queue hop needed
            view.writeCallback?(swiftData)
        }, userdata)
    }

}

// MARK: - Gesture Recognizer Delegate

extension GhosttyTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pan and long press to recognize simultaneously
        // The handlers check isSelecting/isScrolling to avoid conflicts
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Long press should win over pan when held long enough
        if gestureRecognizer == scrollRecognizer && otherGestureRecognizer == selectionRecognizer {
            // Only require failure if long press is about to recognize
            return otherGestureRecognizer.state == .began
        }
        return false
    }
}

// MARK: - Keyboard Accessory View

extension GhosttyTerminalView {
    private static var keyboardToolbarKey: UInt8 = 0

    private var keyboardToolbar: TerminalInputAccessoryView? {
        get { objc_getAssociatedObject(self, &Self.keyboardToolbarKey) as? TerminalInputAccessoryView }
        set { objc_setAssociatedObject(self, &Self.keyboardToolbarKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    override var inputAccessoryView: UIView? {
        if keyboardToolbar == nil {
            let toolbar = TerminalInputAccessoryView { [weak self] key in
                self?.handleToolbarKey(key)
            }
            keyboardToolbar = toolbar
        }
        return keyboardToolbar
    }

    private func handleToolbarKey(_ key: TerminalKey) {
        let data = key.ansiSequence
        if let text = String(data: data, encoding: .utf8) {
            sendText(text)
        } else {
            surface?.sendText(String(decoding: data, as: UTF8.self))
        }
    }
}

// MARK: - Native UIKit Input Accessory View

private class TerminalInputAccessoryView: UIView {
    private let onKey: (TerminalKey) -> Void
    private var scrollView: UIScrollView!
    private var stackView: UIStackView!
    private var ctrlActive = false
    private var altActive = false
    private var ctrlButton: UIButton?
    private var altButton: UIButton?

    init(onKey: @escaping (TerminalKey) -> Void) {
        self.onKey = onKey
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupView() {
        autoresizingMask = [.flexibleWidth]

        // Glass/blur background
        let blurEffect = UIBlurEffect(style: .systemMaterial)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Scroll view for horizontal scrolling
        scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        // Stack view for buttons
        stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 8
        stackView.alignment = .center
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        // Add buttons
        addModifierButtons()
        addDivider()
        addKeyButtons()
        addDivider()
        addArrowButtons()
        addDivider()
        addControlButtons()
        addDivider()
        addNavigationButtons()
    }

    private func addModifierButtons() {
        ctrlButton = createButton(title: "Ctrl", action: #selector(toggleCtrl))
        altButton = createButton(title: "Alt", action: #selector(toggleAlt))
        stackView.addArrangedSubview(ctrlButton!)
        stackView.addArrangedSubview(altButton!)
    }

    private func addKeyButtons() {
        stackView.addArrangedSubview(createButton(title: "Esc", action: #selector(tapEsc)))
        stackView.addArrangedSubview(createButton(icon: "arrow.right.to.line", action: #selector(tapTab)))
    }

    private func addArrowButtons() {
        stackView.addArrangedSubview(createButton(icon: "arrow.up", action: #selector(tapUp)))
        stackView.addArrangedSubview(createButton(icon: "arrow.down", action: #selector(tapDown)))
        stackView.addArrangedSubview(createButton(icon: "arrow.left", action: #selector(tapLeft)))
        stackView.addArrangedSubview(createButton(icon: "arrow.right", action: #selector(tapRight)))
    }

    private func addControlButtons() {
        stackView.addArrangedSubview(createButton(title: "^C", action: #selector(tapCtrlC)))
        stackView.addArrangedSubview(createButton(title: "^D", action: #selector(tapCtrlD)))
        stackView.addArrangedSubview(createButton(title: "^Z", action: #selector(tapCtrlZ)))
        stackView.addArrangedSubview(createButton(title: "^L", action: #selector(tapCtrlL)))
    }

    private func addNavigationButtons() {
        stackView.addArrangedSubview(createButton(title: "Home", action: #selector(tapHome)))
        stackView.addArrangedSubview(createButton(title: "End", action: #selector(tapEnd)))
        stackView.addArrangedSubview(createButton(title: "PgUp", action: #selector(tapPgUp)))
        stackView.addArrangedSubview(createButton(title: "PgDn", action: #selector(tapPgDn)))
    }

    private func addDivider() {
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stackView.addArrangedSubview(divider)
    }

    private func createButton(title: String? = nil, icon: String? = nil, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        config.background.backgroundColor = .quaternarySystemFill
        config.background.cornerRadius = 6
        config.baseForegroundColor = .label

        if let icon = icon {
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            config.image = UIImage(systemName: icon, withConfiguration: symbolConfig)
        } else if let title = title {
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
                return outgoing
            }
        }

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)

        let minWidth: CGFloat = title != nil ? 40 : 36
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true

        return button
    }

    private func sendKey(_ key: TerminalKey) {
        var modifiedKey = key
        if ctrlActive {
            modifiedKey = key.withCtrl()
            ctrlActive = false
            updateModifierButton(ctrlButton, active: false)
        }
        if altActive {
            modifiedKey = key.withAlt()
            altActive = false
            updateModifierButton(altButton, active: false)
        }
        onKey(modifiedKey)
    }

    private func updateModifierButton(_ button: UIButton?, active: Bool) {
        guard var config = button?.configuration else { return }
        UIView.animate(withDuration: 0.15) {
            config.background.backgroundColor = active ? .systemBlue : .quaternarySystemFill
            config.baseForegroundColor = active ? .white : .label
            button?.configuration = config
        }
    }

    // MARK: - Button Actions

    @objc private func toggleCtrl() {
        ctrlActive.toggle()
        updateModifierButton(ctrlButton, active: ctrlActive)
    }

    @objc private func toggleAlt() {
        altActive.toggle()
        updateModifierButton(altButton, active: altActive)
    }

    @objc private func tapEsc() { sendKey(.escape) }
    @objc private func tapTab() { sendKey(.tab) }
    @objc private func tapUp() { sendKey(.arrowUp) }
    @objc private func tapDown() { sendKey(.arrowDown) }
    @objc private func tapLeft() { sendKey(.arrowLeft) }
    @objc private func tapRight() { sendKey(.arrowRight) }
    @objc private func tapCtrlC() { sendKey(.ctrlC) }
    @objc private func tapCtrlD() { sendKey(.ctrlD) }
    @objc private func tapCtrlZ() { sendKey(.ctrlZ) }
    @objc private func tapCtrlL() { sendKey(.ctrlL) }
    @objc private func tapHome() { sendKey(.home) }
    @objc private func tapEnd() { sendKey(.end) }
    @objc private func tapPgUp() { sendKey(.pageUp) }
    @objc private func tapPgDn() { sendKey(.pageDown) }
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
