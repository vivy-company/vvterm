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

    /// Callback invoked when the voice input button is tapped
    var onVoiceButtonTapped: (() -> Void)? {
        didSet {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
    }
    private var didSignalReady = false

    /// Prevent rendering when the view is offscreen or being torn down.
    private var isShuttingDown = false
    private var isPaused = false
    private var displayLink: CADisplayLink?
    private var needsRender = false
    private var blinkTimer: DispatchSourceTimer?

    /// Idle detection for display link - stops after timeout to save CPU
    private var lastActivityTime: CFAbsoluteTime = 0
    private static let idleTimeout: CFTimeInterval = 0.1  // 100ms idle before stopping display link
    private static let blinkInterval: TimeInterval = 0.5  // Cursor blink cadence when idle

    /// Track last surface size in pixels to avoid redundant resize/draw work.
    private var lastPixelSize: CGSize = .zero
    private var lastContentScale: CGFloat = 0

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
        recognizer.minimumPressDuration = 0.2
        recognizer.allowableMovement = 8
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()

    private lazy var tripleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTripleTap(_:))
        )
        recognizer.numberOfTapsRequired = 3
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

    private var editMenuInteraction: UIEditMenuInteraction?

    /// Observer for config reload notifications
    private var configReloadObserver: NSObjectProtocol?

    // MARK: - Rendering Components

    private let renderingSetup = GhosttyRenderingSetup()

    private func requestRender() {
        if isShuttingDown { return }
        if isPaused { return }
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
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func startBlinkTimerIfNeeded() {
        guard blinkTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.blinkInterval, repeating: Self.blinkInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard !self.isShuttingDown, !self.isPaused, self.window != nil else { return }
            // Tick Ghostty to advance cursor blink state, then render a frame.
            self.ghosttyAppWrapper?.appTick()
            self.requestRender()
        }
        timer.resume()
        blinkTimer = timer
    }

    private func stopBlinkTimer() {
        blinkTimer?.cancel()
        blinkTimer = nil
    }

    @objc private func displayLinkTick() {
        guard !isShuttingDown, !isPaused else { return }

        // Check if we've been idle too long
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            stopDisplayLink()
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
        doubleTapRecognizer.delegate = self
        tripleTapRecognizer.delegate = self

        // Triple tap should require double tap to fail first
        doubleTapRecognizer.require(toFail: tripleTapRecognizer)

        addGestureRecognizer(selectionRecognizer)
        addGestureRecognizer(scrollRecognizer)
        addGestureRecognizer(doubleTapRecognizer)
        addGestureRecognizer(tripleTapRecognizer)
        isUserInteractionEnabled = true

        // Setup edit menu interaction for copy/paste
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenuInteraction = interaction

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
        stopBlinkTimer()
        stopMomentumScrolling()

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
        stopBlinkTimer()

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
        sizeDidChange(bounds.size)
        requestRender()
        if window != nil {
            startBlinkTimerIfNeeded()
        }
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
        configureIOSurfaceLayers(size: bounds.size)

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
        if isShuttingDown { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard size.width > 0 && size.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: size)

        let scale = self.contentScaleFactor
        let pixelWidth = floor(size.width * scale)
        let pixelHeight = floor(size.height * scale)
        guard pixelWidth > 0 && pixelHeight > 0 else { return }
        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

        // Avoid redundant resize/draw passes when size hasn't changed.
        let sizeChanged = pixelSize != lastPixelSize || scale != lastContentScale
        if !sizeChanged {
            if !didSignalReady {
                didSignalReady = true
                DispatchQueue.main.async { [weak self] in
                    self?.onReady?()
                }
            }
            return
        }
        lastPixelSize = pixelSize
        lastContentScale = scale

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(pixelWidth),
            UInt32(pixelHeight)
        )

        if !isPaused {
            // CRITICAL: iOS has no CADisplayLink - explicitly trigger rendering
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }

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

        // Tell Ghostty the new size after the view has laid out.
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
            sizeDidChange(frame.size)
            // Note: becomeFirstResponder is now handled by SSHTerminalWrapper.updateUIView
            // based on isActive flag to avoid keyboard showing when terminal is hidden
            // Request render to start display link if needed (event-driven)
            requestRender()
            startBlinkTimerIfNeeded()
        } else {
            stopDisplayLink()
            stopBlinkTimer()
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

    /// Scroll speed multiplier for iOS touch scrolling
    private static let scrollMultiplier: Double = 1.5

    /// Momentum deceleration rate (0.0-1.0, higher = slower deceleration)
    private static let momentumDeceleration: Double = 0.92

    /// Minimum velocity to trigger momentum scrolling
    private static let minimumMomentumVelocity: Double = 50.0

    /// Display link for momentum animation
    private var momentumDisplayLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let surface = surface else { return }
        if isSelecting { return }

        let translation = recognizer.translation(in: self)

        switch recognizer.state {
        case .began:
            isScrolling = true
            stopMomentumScrolling()
        case .changed:
            // Send scroll delta directly with increased multiplier for snappy feel
            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: Double(translation.x) * Self.scrollMultiplier,
                y: Double(translation.y) * Self.scrollMultiplier,
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .changed)
            )
            surface.sendMouseScroll(scrollEvent)
            requestRender()

            // Reset translation so we get delta on next call
            recognizer.setTranslation(.zero, in: self)
        case .ended:
            isScrolling = false
            // Get velocity for momentum scrolling
            let velocity = recognizer.velocity(in: self)
            startMomentumScrolling(velocity: velocity)
        case .cancelled, .failed:
            isScrolling = false
            stopMomentumScrolling()
        default:
            break
        }
    }

    private func startMomentumScrolling(velocity: CGPoint) {
        // Only start momentum if velocity is significant
        guard abs(velocity.y) > Self.minimumMomentumVelocity || abs(velocity.x) > Self.minimumMomentumVelocity else {
            sendMomentumEnd()
            return
        }

        // Scale velocity for momentum (divide by 60 for per-frame amount at 60fps)
        momentumVelocity = CGPoint(
            x: velocity.x / 60.0 * Self.scrollMultiplier * 0.5,
            y: velocity.y / 60.0 * Self.scrollMultiplier * 0.5
        )

        // Create display link for smooth animation
        momentumDisplayLink = CADisplayLink(target: self, selector: #selector(momentumScrollTick))
        momentumDisplayLink?.add(to: .main, forMode: .common)
    }

    @objc private func momentumScrollTick() {
        guard let surface = surface else {
            stopMomentumScrolling()
            return
        }

        // Apply deceleration
        momentumVelocity.x *= Self.momentumDeceleration
        momentumVelocity.y *= Self.momentumDeceleration

        // Stop if velocity is very low
        if abs(momentumVelocity.x) < 0.5 && abs(momentumVelocity.y) < 0.5 {
            stopMomentumScrolling()
            sendMomentumEnd()
            return
        }

        // Send momentum scroll event
        let scrollEvent = Ghostty.Input.MouseScrollEvent(
            x: Double(momentumVelocity.x),
            y: Double(momentumVelocity.y),
            mods: Ghostty.Input.ScrollMods(precision: true, momentum: .changed)
        )
        surface.sendMouseScroll(scrollEvent)
        requestRender()
    }

    private func stopMomentumScrolling() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        momentumVelocity = .zero
    }

    private func sendMomentumEnd() {
        guard let surface = surface else { return }
        let endEvent = Ghostty.Input.MouseScrollEvent(
            x: 0,
            y: 0,
            mods: Ghostty.Input.ScrollMods(precision: true, momentum: .ended)
        )
        surface.sendMouseScroll(endEvent)
    }

    // MARK: - Selection Gestures

    /// Double-tap to select word
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        _ = becomeFirstResponder()

        // Double-click to select word (no modifiers)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        requestRender()

        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }

    /// Triple-tap to select line
    @objc private func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        _ = becomeFirstResponder()

        // Triple-click to select line
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        for _ in 0..<3 {
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        }
        requestRender()

        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }

    /// Long press + drag for custom selection
    @objc private func handleSelectionPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        switch recognizer.state {
        case .began:
            isSelecting = true
            _ = becomeFirstResponder()
            // Start selection with click (no shift for initial position)
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            requestRender()
        case .changed:
            // Drag to extend selection
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            requestRender()
        case .ended, .cancelled, .failed:
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
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
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
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

    private func sendAnsiSequence(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        sendText(text)
    }

    private func sendModifiedKey(_ key: Ghostty.Input.Key, mods: Ghostty.Input.Mods, text: String? = nil, unshiftedCodepoint: UInt32 = 0) {
        guard let surface = surface else { return }
        let press = Ghostty.Input.KeyEvent(
            key: key,
            action: .press,
            text: text,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(press)
        let release = Ghostty.Input.KeyEvent(
            key: key,
            action: .release,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(release)
        requestRender()
    }

    private func sendControlShortcut(_ char: Character) {
        let lower = String(char).lowercased()
        if let key = Ghostty.Input.Key(rawValue: lower) {
            let codepoint = lower.unicodeScalars.first?.value ?? 0
            sendModifiedKey(key, mods: [.ctrl], text: lower, unshiftedCodepoint: codepoint)
            return
        }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            sendText(String(controlChar))
        }
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
        if isShuttingDown { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: bounds.size)

        // Set scale and size
        let scale = self.contentScaleFactor
        let pixelWidth = floor(bounds.width * scale)
        let pixelHeight = floor(bounds.height * scale)
        guard pixelWidth > 0 && pixelHeight > 0 else { return }
        lastPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        lastContentScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(pixelWidth), UInt32(pixelHeight))
        if window != nil {
            ghostty_surface_set_occlusion(surface, false)
        }

        // CRITICAL: iOS has no CADisplayLink - explicitly trigger rendering
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        requestRender()
        if window != nil {
            startBlinkTimerIfNeeded()
        }
    }

    private func configureIOSurfaceLayers() {
        configureIOSurfaceLayers(size: nil)
    }

    private func configureIOSurfaceLayers(size: CGSize?) {
        let scale = self.contentScaleFactor
        guard let sublayers = layer.sublayers else { return }
        let ioLayers = sublayers.filter { String(describing: type(of: $0)) == "IOSurfaceLayer" }
        guard !ioLayers.isEmpty else { return }
        let targetBounds = size.map { CGRect(origin: .zero, size: $0) } ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in ioLayers {
            sublayer.frame = targetBounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func updateContentScaleIfNeeded() {
        let targetScale = window?.screen.scale ?? UIScreen.main.scale
        if contentScaleFactor != targetScale {
            contentScaleFactor = targetScale
        }
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

// MARK: - Edit Menu Interaction Delegate

extension GhosttyTerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions: [UIMenuElement] = []

        if let cSurface = surface?.unsafeCValue, ghostty_surface_has_selection(cSurface) {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        return UIMenu(children: actions)
    }
}

// MARK: - Terminal Key Enum

indirect enum TerminalKey {
    case escape, tab, enter, backspace, delete, insert
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlA, ctrlE, ctrlK, ctrlU
    case ctrl(TerminalKey), alt(TerminalKey), ctrlAlt(TerminalKey)

    func withCtrl() -> TerminalKey {
        switch self {
        case .ctrl, .alt, .ctrlAlt: return self
        default: return .ctrl(self)
        }
    }

    func withAlt() -> TerminalKey {
        switch self {
        case .ctrl(let key): return .ctrlAlt(key)
        case .alt, .ctrlAlt: return self
        default: return .alt(self)
        }
    }

    var ansiSequence: Data {
        switch self {
        case .escape: return Data([0x1B])
        case .tab: return Data([0x09])
        case .enter: return Data([0x0D])
        case .backspace: return Data([0x7F])
        case .delete: return "\u{1B}[3~".data(using: .utf8)!
        case .insert: return "\u{1B}[2~".data(using: .utf8)!
        case .arrowUp: return "\u{1B}[A".data(using: .utf8)!
        case .arrowDown: return "\u{1B}[B".data(using: .utf8)!
        case .arrowRight: return "\u{1B}[C".data(using: .utf8)!
        case .arrowLeft: return "\u{1B}[D".data(using: .utf8)!
        case .home: return "\u{1B}[H".data(using: .utf8)!
        case .end: return "\u{1B}[F".data(using: .utf8)!
        case .pageUp: return "\u{1B}[5~".data(using: .utf8)!
        case .pageDown: return "\u{1B}[6~".data(using: .utf8)!
        case .f1: return "\u{1B}OP".data(using: .utf8)!
        case .f2: return "\u{1B}OQ".data(using: .utf8)!
        case .f3: return "\u{1B}OR".data(using: .utf8)!
        case .f4: return "\u{1B}OS".data(using: .utf8)!
        case .f5: return "\u{1B}[15~".data(using: .utf8)!
        case .f6: return "\u{1B}[17~".data(using: .utf8)!
        case .f7: return "\u{1B}[18~".data(using: .utf8)!
        case .f8: return "\u{1B}[19~".data(using: .utf8)!
        case .f9: return "\u{1B}[20~".data(using: .utf8)!
        case .f10: return "\u{1B}[21~".data(using: .utf8)!
        case .f11: return "\u{1B}[23~".data(using: .utf8)!
        case .f12: return "\u{1B}[24~".data(using: .utf8)!
        case .ctrlC: return Data([0x03])
        case .ctrlD: return Data([0x04])
        case .ctrlZ: return Data([0x1A])
        case .ctrlL: return Data([0x0C])
        case .ctrlA: return Data([0x01])
        case .ctrlE: return Data([0x05])
        case .ctrlK: return Data([0x0B])
        case .ctrlU: return Data([0x15])
        case .ctrl(let key): return key.ansiSequence
        case .alt(let key):
            var data = Data([0x1B])
            data.append(key.ansiSequence)
            return data
        case .ctrlAlt(let key):
            var data = Data([0x1B])
            data.append(key.ansiSequence)
            return data
        }
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
            let toolbar = TerminalInputAccessoryView(onKey: { [weak self] key in
                self?.handleToolbarKey(key)
            }, onVoice: onVoiceButtonTapped)
            keyboardToolbar = toolbar
        } else {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
        return keyboardToolbar
    }

    private func handleToolbarKey(_ key: TerminalKey) {
        // Use Ghostty key events for navigation keys (proper terminal escape sequences)
        switch key {
        case .escape:
            sendKeyPress(.escape)
        case .tab:
            sendKeyPress(.tab)
        case .enter:
            sendKeyPress(.enter)
        case .backspace:
            sendKeyPress(.backspace)
        case .delete:
            sendKeyPress(.delete)
        case .insert:
            sendKeyPress(.insert)
        case .arrowUp:
            sendKeyPress(.arrowUp)
        case .arrowDown:
            sendKeyPress(.arrowDown)
        case .arrowLeft:
            sendKeyPress(.arrowLeft)
        case .arrowRight:
            sendKeyPress(.arrowRight)
        case .home:
            sendKeyPress(.home)
        case .end:
            sendKeyPress(.end)
        case .pageUp:
            sendKeyPress(.pageUp)
        case .pageDown:
            sendKeyPress(.pageDown)
        case .f1:
            sendKeyPress(.f1)
        case .f2:
            sendKeyPress(.f2)
        case .f3:
            sendKeyPress(.f3)
        case .f4:
            sendKeyPress(.f4)
        case .f5:
            sendKeyPress(.f5)
        case .f6:
            sendKeyPress(.f6)
        case .f7:
            sendKeyPress(.f7)
        case .f8:
            sendKeyPress(.f8)
        case .f9:
            sendKeyPress(.f9)
        case .f10:
            sendKeyPress(.f10)
        case .f11:
            sendKeyPress(.f11)
        case .f12:
            sendKeyPress(.f12)
        case .ctrlC, .ctrlD, .ctrlZ, .ctrlL, .ctrlA, .ctrlE, .ctrlK, .ctrlU:
            switch key {
            case .ctrlC: sendControlShortcut("c")
            case .ctrlD: sendControlShortcut("d")
            case .ctrlZ: sendControlShortcut("z")
            case .ctrlL: sendControlShortcut("l")
            case .ctrlA: sendControlShortcut("a")
            case .ctrlE: sendControlShortcut("e")
            case .ctrlK: sendControlShortcut("k")
            case .ctrlU: sendControlShortcut("u")
            default:
                sendAnsiSequence(key.ansiSequence)
            }
        case .ctrl, .alt, .ctrlAlt:
            // Modified keys - use ANSI sequence
            sendAnsiSequence(key.ansiSequence)
        }
    }
}

// MARK: - Native UIKit Input Accessory View with Glass Effect

private class TerminalInputAccessoryView: UIInputView {
    private let onKey: (TerminalKey) -> Void
    var onVoice: (() -> Void)? {
        didSet {
            updateVoiceButtonState()
        }
    }
    private var ctrlActive = false
    private var altActive = false
    private weak var ctrlButton: UIButton?
    private weak var altButton: UIButton?
    private weak var voiceButton: UIButton?

    init(onKey: @escaping (TerminalKey) -> Void, onVoice: (() -> Void)? = nil) {
        self.onKey = onKey
        self.onVoice = onVoice
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48), inputViewStyle: .keyboard)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupView() {
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        let voice = makeIconButton(icon: "mic.fill", action: #selector(tapVoice))
        voice.accessibilityLabel = String(localized: "Voice input")
        voiceButton = voice
        voice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(voice)

        let voiceSeparator = makeSeparator()
        addSubview(voiceSeparator)

        NSLayoutConstraint.activate([
            voice.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            voice.centerYAnchor.constraint(equalTo: centerYAnchor),

            voiceSeparator.leadingAnchor.constraint(equalTo: voice.trailingAnchor, constant: 10),
            voiceSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: voiceSeparator.trailingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -16)
        ])

        // Modifier buttons (toggle style)
        let ctrl = makeModifierButton(title: String(localized: "Ctrl"), action: #selector(toggleCtrl))
        let alt = makeModifierButton(title: String(localized: "Alt"), action: #selector(toggleAlt))
        ctrlButton = ctrl
        altButton = alt
        stack.addArrangedSubview(ctrl)
        stack.addArrangedSubview(alt)
        stack.addArrangedSubview(makeSeparator())

        // Control sequences
        stack.addArrangedSubview(makePillButton(title: String(localized: "^C"), action: #selector(tapCtrlC)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "^D"), action: #selector(tapCtrlD)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "^Z"), action: #selector(tapCtrlZ)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "^L"), action: #selector(tapCtrlL)))
        stack.addArrangedSubview(makeSeparator())

        // Common keys
        stack.addArrangedSubview(makePillButton(title: String(localized: "Esc"), action: #selector(tapEsc)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "Tab"), action: #selector(tapTab)))
        stack.addArrangedSubview(makeSeparator())

        // Arrow keys
        stack.addArrangedSubview(makeIconButton(icon: "arrow.up", action: #selector(tapUp)))
        stack.addArrangedSubview(makeIconButton(icon: "arrow.down", action: #selector(tapDown)))
        stack.addArrangedSubview(makeIconButton(icon: "arrow.left", action: #selector(tapLeft)))
        stack.addArrangedSubview(makeIconButton(icon: "arrow.right", action: #selector(tapRight)))
        stack.addArrangedSubview(makeSeparator())

        // Navigation
        stack.addArrangedSubview(makePillButton(title: String(localized: "Home"), action: #selector(tapHome)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "End"), action: #selector(tapEnd)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "PgUp"), action: #selector(tapPgUp)))
        stack.addArrangedSubview(makePillButton(title: String(localized: "PgDn"), action: #selector(tapPgDn)))

        updateVoiceButtonState()
    }

    private func makePillButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)])
            )
            config.baseForegroundColor = .label
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.setTitleColor(.label, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16
        button.addTarget(self, action: action, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeIconButton(icon: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16
        button.addTarget(self, action: action, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeModifierButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .semibold)])
            )
            config.baseForegroundColor = .secondaryLabel
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.setTitleColor(.secondaryLabel, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.08)
                : UIColor.black.withAlphaComponent(0.04)
        }
        button.layer.cornerRadius = 14
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
        button.addTarget(self, action: action, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 28)
        ])

        return button
    }

    private func makeSeparator() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator.withAlphaComponent(0.4)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 18)
        ])
        return view
    }

    private func sendKey(_ key: TerminalKey) {
        var modifiedKey = key
        if ctrlActive {
            modifiedKey = modifiedKey.withCtrl()
            ctrlActive = false
            updateModifierState()
        }
        if altActive {
            modifiedKey = modifiedKey.withAlt()
            altActive = false
            updateModifierState()
        }
        onKey(modifiedKey)
    }

    func consumeModifiers() -> (ctrl: Bool, alt: Bool) {
        let ctrl = ctrlActive
        let alt = altActive
        if ctrl || alt {
            ctrlActive = false
            altActive = false
            updateModifierState()
        }
        return (ctrl, alt)
    }

    private func updateModifierState() {
        UIView.animate(withDuration: 0.2) {
            // Ctrl button
            if self.ctrlActive {
                self.ctrlButton?.backgroundColor = .systemBlue
                self.ctrlButton?.setTitleColor(.white, for: .normal)
                self.ctrlButton?.layer.borderColor = UIColor.clear.cgColor
            } else {
                self.ctrlButton?.backgroundColor = UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor.white.withAlphaComponent(0.08)
                        : UIColor.black.withAlphaComponent(0.04)
                }
                self.ctrlButton?.setTitleColor(.secondaryLabel, for: .normal)
                self.ctrlButton?.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
            }

            // Alt button
            if self.altActive {
                self.altButton?.backgroundColor = .systemBlue
                self.altButton?.setTitleColor(.white, for: .normal)
                self.altButton?.layer.borderColor = UIColor.clear.cgColor
            } else {
                self.altButton?.backgroundColor = UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor.white.withAlphaComponent(0.08)
                        : UIColor.black.withAlphaComponent(0.04)
                }
                self.altButton?.setTitleColor(.secondaryLabel, for: .normal)
                self.altButton?.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
            }
        }
    }

    private func updateVoiceButtonState() {
        let enabled = onVoice != nil
        voiceButton?.isEnabled = enabled
        voiceButton?.alpha = enabled ? 1.0 : 0.35
    }

    @objc private func toggleCtrl() {
        ctrlActive.toggle()
        updateModifierState()
    }

    @objc private func toggleAlt() {
        altActive.toggle()
        updateModifierState()
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
    @objc private func tapVoice() { onVoice?() }
}

// MARK: - Software Keyboard (UIKeyInput)

extension GhosttyTerminalView: UIKeyInput, UITextInputTraits {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if let toolbar = keyboardToolbar {
            let mods = toolbar.consumeModifiers()
            if mods.ctrl || mods.alt {
                if let firstChar = text.first {
                    let lower = String(firstChar).lowercased()
                    if let key = Ghostty.Input.Key(rawValue: lower) {
                        var ghostMods: Ghostty.Input.Mods = []
                        if mods.ctrl { ghostMods.insert(.ctrl) }
                        if mods.alt { ghostMods.insert(.alt) }
                        let codepoint = lower.unicodeScalars.first?.value ?? 0
                        sendModifiedKey(key, mods: ghostMods, text: lower, unshiftedCodepoint: codepoint)
                    } else {
                        var data = Data()
                        if mods.alt {
                            data.append(0x1B)
                        }
                        if mods.ctrl, let controlChar = TerminalControlKey.controlCharacter(for: firstChar) {
                            data.append(contentsOf: String(controlChar).utf8)
                        } else {
                            data.append(contentsOf: String(firstChar).utf8)
                        }
                        sendAnsiSequence(data)
                    }

                    if text.count > 1 {
                        sendText(String(text.dropFirst()))
                    }
                    return
                }
            }
        }

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
