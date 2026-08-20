//
//  GhosttyTerminalView+macOS.swift
//  VVTerm
//
//  macOS NSView implementation for Ghostty terminal rendering
//

#if os(macOS)
import AppKit
import CoreVideo
import OSLog

/// NSView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering
/// - Input forwarding (keyboard, mouse, scroll)
/// - Focus management
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: NSView, NSUserInterfaceValidations {
    // MARK: - Properties

    var ghosttyApp: ghostty_app_t?
    weak var ghosttyAppWrapper: GhosttyRuntime?
    internal var surface: Ghostty.Surface?
    var surfaceReference: Ghostty.SurfaceReference?
    let worktreePath: String
    let paneId: String?
    let initialCommand: String?
    let useCustomIO: Bool

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

    /// Callback invoked when a magnification gesture requests terminal pane zoom.
    var onZoomAction: ((TerminalZoomAction) -> TerminalZoomResult?)?

    /// Per-surface presentation overrides used to preserve pane zoom across global config reloads.
    var surfacePresentationOverrides: TerminalPresentationOverrides = .empty

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?

    /// Optional pane/session actions exposed in the macOS contextual menu.
    var terminalContextMenuActions: TerminalContextMenuActions?

    var didSignalReady = false
    var readonly = false
    let clipboardConfirmationQueue = TerminalClipboardConfirmationQueue()
    var presentedClipboardConfirmation: NSAlert?
    var clipboardConfirmationRetryWorkItem: DispatchWorkItem?
    var clipboardConfirmationRetryCount = 0

    /// Cell size in points for row-to-pixel conversion (used by scroll view)
    var cellSize: NSSize = .zero

    /// Current scrollbar state from Ghostty core (used by scroll view)
    var scrollbar: Ghostty.Action.Scrollbar?

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm", category: "GhosttyTerminal")

    // MARK: - Display Link Rendering (event-driven for SSH)

    var displayLink: CVDisplayLink?
    var needsRender = false
    var accumulatedMagnification: CGFloat = 0
    let zoomIndicatorView = TerminalZoomIndicatorView()
    var zoomIndicatorHideWorkItem: DispatchWorkItem?

    /// Idle detection for display link - stops after timeout to save CPU
    var lastActivityTime: CFAbsoluteTime = 0
    var idleCheckTimer: DispatchSourceTimer?
    static let idleTimeout: CFTimeInterval = 0.1  // 100ms idle before stopping display link

    // MARK: - Handler Components

    var imeHandler: GhosttyIMEHandler!
    var inputHandler: GhosttyInputHandler!
    let renderingSetup = GhosttyRenderingSetup()

    /// Observation for appearance changes
    var appearanceObservation: NSKeyValueObservation?

    /// Observer for config reload notifications
    var configReloadObserver: NSObjectProtocol?

    // MARK: - Rendering Control

    /// Flag to prevent operations during cleanup
    var isShuttingDown = false

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The GhosttyRuntime wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane (used for tmux session persistence)
    ///   - command: Optional command to run instead of default shell
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(frame: NSRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: GhosttyRuntime? = nil, paneId: String? = nil, command: String? = nil, useCustomIO: Bool = false) {
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
        zoomIndicatorView.isHidden = true
        zoomIndicatorView.alphaValue = 0
        addSubview(zoomIndicatorView)
        if useCustomIO {
            setupDisplayLink()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    isolated deinit {
        cleanup()
    }

    // MARK: - Setup

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

    /// Callback context retained by display link - must be released when display link stops
    var displayLinkCallbackContext: Unmanaged<DisplayLinkCallbackContext>?

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

    // Track last size sent to Ghostty to avoid redundant updates
    var lastSurfaceSize: CGSize = .zero

    // MARK: - Custom I/O API (for SSH clients)

    /// Callback invoked when user types in the terminal (keyboard input to send to SSH)
    var writeCallback: ((Data) -> Void)?
}

#endif
