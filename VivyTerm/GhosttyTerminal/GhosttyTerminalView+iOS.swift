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
