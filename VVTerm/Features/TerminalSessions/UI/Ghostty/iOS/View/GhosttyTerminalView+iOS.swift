//
//  GhosttyTerminalView+iOS.swift
//  VVTerm
//
//  iOS UIView implementation for Ghostty terminal rendering
//

#if os(iOS)
import UIKit
import Metal
import OSLog
import SwiftUI
import IOSurface
import CoreImage

nonisolated enum TerminalSurfaceGeometryUpdate: Equatable, Sendable {
    case apply
    case preserveCurrentGrid
}

nonisolated enum TerminalSurfaceGeometryPolicy {
    static func update(
        renderingIsPaused: Bool,
        preservesForegroundKeyboardGrid: Bool,
        currentSize: CGSize,
        proposedSize: CGSize
    ) -> TerminalSurfaceGeometryUpdate {
        if renderingIsPaused {
            return .preserveCurrentGrid
        }
        if preservesForegroundKeyboardGrid,
           abs(proposedSize.width - currentSize.width) < 0.5,
           proposedSize.height > currentSize.height + 0.5 {
            return .preserveCurrentGrid
        }
        return .apply
    }
}

/// UIView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering (Ghostty handles this internally)
/// - Touch and keyboard input
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: UIView {
    static let textInputContextID = "app.vivy.VVTerm.GhosttyTerminalView"
    // MARK: - Properties

    var ghosttyApp: ghostty_app_t?
    weak var ghosttyAppWrapper: GhosttyRuntime?
    internal var surface: Ghostty.Surface?
    var surfaceReference: Ghostty.SurfaceReference?
    let worktreePath: String
    let paneId: String?
    let initialCommand: String?
    let useCustomIO: Bool
    var terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot
    var keyboardToolbar: TerminalInputAccessoryView?

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback invoked when the terminal reports working directory changes (OSC 7)
    var onPwdChange: ((String) -> Void)?

    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?

    /// Callback invoked when the terminal grid changes (cols, rows).
    /// In custom I/O mode (SSH), the embedder should send a window-change.
    var onResize: ((Int, Int) -> Void)?

    /// Optional UI-layer observer used by the opt-in keyboard viewport policy.
    /// It is called only when the rendered cursor rect changes.
    var onKeyboardAvoidanceCursorRectChange: ((CGRect) -> Void)?
    /// Reports input-accessory host movement independently of software-keyboard
    /// geometry. Floating iPad keyboards can leave this view docked at the
    /// bottom of the screen.
    var onKeyboardAvoidanceAccessoryFrameChange: (() -> Void)?
    var lastKeyboardAvoidanceAccessoryFrame: CGRect?
    var keyboardAvoidancePreservedSurfaceSize: CGSize?
    var keyboardAvoidanceReferenceSurfaceSize: CGSize?
    var tracksKeyboardAvoidanceReferenceSize = false

    /// Callback invoked when a pinch gesture requests terminal pane zoom.
    var onZoomAction: ((TerminalZoomAction) -> TerminalZoomResult?)?

    /// App-owned pane actions invoked by local iPad keyboard shortcuts.
    var onPaneKeyboardShortcut: ((TerminalSplitCommand) -> Void)?

    /// Per-surface presentation overrides used to preserve pane zoom across global config reloads.
    var surfacePresentationOverrides: TerminalPresentationOverrides = .empty

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?

    /// Callback invoked when the voice input button is tapped
    var onVoiceButtonTapped: (() -> Void)? {
        didSet {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
    }

    @discardableResult
    func triggerVoiceInput() -> Bool {
        guard let onVoiceButtonTapped else { return false }
        onVoiceButtonTapped()
        return true
    }

    @discardableResult
    func sendReturnKey() -> Bool {
        guard canRouteTerminalInput else { return false }
        sendToolbarKey(.enter)
        return true
    }

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?

    /// Callback invoked when custom terminal I/O emits user input.
    var writeCallback: ((Data) -> Void)?

    /// Optional pane/session actions exposed in the iPad pointer contextual menu.
    var terminalContextMenuActions: TerminalContextMenuActions?

    var didSignalReady = false
    var readonly = false
    let clipboardConfirmationQueue = TerminalClipboardConfirmationQueue()
    var presentedClipboardConfirmation: UIAlertController?
    var clipboardConfirmationRetryWorkItem: DispatchWorkItem?
    var clipboardConfirmationRetryCount = 0

    /// Prevent rendering when the view is offscreen or being torn down.
    var isShuttingDown = false
    var isPaused = false
    var preservesForegroundKeyboardGrid = false
    #if DEBUG
    var keyboardUITestSurfaceFocused = false
    var keyboardUITestGridResizeCount = 0
    #endif
    var customIORedrawScheduled = false
    var keyRepeatTimer: DispatchSourceTimer?
    var hardwareKeyRepeatState = TerminalHardwareKeyRepeatState<Ghostty.Input.KeyEvent>()
    #if DEBUG
    var keyboardUITestUsesManualHardwareKeyRepeatClock = false
    #endif

    /// Track last surface size in pixels to avoid redundant resize/draw work.
    var lastPixelSize: CGSize = .zero
    var lastContentScale: CGFloat = 0
    var lastReportedGrid: (cols: Int, rows: Int) = (0, 0)

    var currentTerminalGridSize: (cols: Int, rows: Int)? {
        guard let size = terminalSize() else { return nil }
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    var currentTerminalPixelSize: TerminalPixelSize? {
        TerminalPixelSize(size: lastPixelSize)
    }
    var lastKeyboardAvoidanceCursorRect: CGRect?
    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyTerminal")

    var isScrolling = false
    var isPinchingTerminalZoom = false
    var pinchReferenceScale: CGFloat = 1
    let zoomIndicatorView = TerminalZoomIndicatorView()
    var zoomIndicatorHideWorkItem: DispatchWorkItem?
    var nativeSelectionSnapshot = TerminalNativeTextSnapshot.empty
    var nativeSelectionLifecycle = TerminalNativeSelectionLifecycle()
    var nativeSelectionLongPressAnchor: NSRange?
    var nativeSelectedRange: NSRange? { nativeSelectionLifecycle.selection }
    var nativeSelectionInteractionActive: Bool { nativeSelectionLifecycle.interactionIsActive }
    var prefersNativeSelectionFirstResponder: Bool { nativeSelectionLifecycle.keepsFirstResponder }
    var nativeTextInteraction: UITextInteraction?
    var nativeFindInteraction: UIFindInteraction?
    @available(iOS 16.0, *)
    var nativeFindSession: GhosttyNativeFindSession?
    var ghosttyFindReportedTotal: Int?
    var ghosttyFindReportedSelectedIndex: Int?
    let nativeFindDocumentIdentifier = "terminal"
    let nativeFindOverlay = TerminalNativeFindOverlayView()
    var nativeFindDecorations: [TerminalNativeFindDecoration] = [] {
        didSet {
            updateNativeFindOverlay()
        }
    }
    lazy var directTouchTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDirectTouchTap(_:))
        )
        recognizer.numberOfTapsRequired = 1
        recognizer.numberOfTouchesRequired = 1
        recognizer.cancelsTouchesInView = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        return recognizer
    }()
    lazy var nativeSelectionLongPressRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleNativeSelectionLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.2
        recognizer.cancelsTouchesInView = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        recognizer.delegate = self
        return recognizer
    }()
    lazy var scrollRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGesture(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        recognizer.requiresExclusiveTouchType = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        if #available(iOS 13.4, *) {
            recognizer.allowedScrollTypesMask = .all
        }
        return recognizer
    }()
    private lazy var pointerHoverRecognizer: UIHoverGestureRecognizer = {
        UIHoverGestureRecognizer(target: self, action: #selector(handlePointerHover(_:)))
    }()
    lazy var pinchRecognizer: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(
            target: self,
            action: #selector(handlePinchGesture(_:))
        )
        recognizer.requiresExclusiveTouchType = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        return recognizer
    }()
    var editMenuInteraction: UIEditMenuInteraction?
    weak var terminalTitleEditor: UIAlertController?
    var editMenuPresentation: TerminalEditMenuPresentation = .selection
    var activePointerButton: TerminalPointerButton?

    /// Observer for config reload notifications
    var configReloadObserver: NSObjectProtocol?
    var inputModeObserver: NSObjectProtocol?
    var hardwareKeyboardObservers: [NSObjectProtocol] = []
    var hasHardwareKeyboardAttached = false

    // MARK: - Text Input (for spacebar cursor control)
    var textInputModel = TerminalTextInputModel()
    var pendingSystemTextInputHardwareKeys: [UIKey] = []
    var suppressIMEProxyCallbacks = false
    var renderedIMEPreeditText: String?
    lazy var imeProxyTextView: TerminalIMEProxyTextView = {
        let textView = TerminalIMEProxyTextView(frame: bounds)
        textView.terminalOwner = self
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isUserInteractionEnabled = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) {
            textView.inlinePredictionType = .no
        }
        return textView
    }()
    lazy var terminalZoomCommands = makeTerminalZoomKeyCommands(
        action: #selector(handleTerminalZoomCommand(_:))
    )
    lazy var terminalSplitCommands = makeTerminalSplitKeyCommands(
        action: #selector(handleTerminalSplitCommand(_:))
    )
    var hardwarePressesSentToGhostty: [UInt16: Ghostty.Input.KeyEvent] = [:]
    var systemTextInputPresses: Set<UInt16> = []
    var terminalAltOptionKeyCodes: Set<UInt16> = []

    struct HardwarePressResult {
        var forwardedToSystem: Set<UIPress> = []
        var didHandleGhosttyInput = false
    }

    // MARK: - Rendering Components

    let renderingSetup = GhosttyRenderingSetup()


    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The GhosttyRuntime wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane
    ///   - command: Optional command to run instead of default shell
    ///   - terminalAccessoryInputSnapshot: App-owned keyboard accessory configuration
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(
        frame: CGRect,
        worktreePath: String,
        ghosttyApp: ghostty_app_t,
        appWrapper: GhosttyRuntime? = nil,
        paneId: String? = nil,
        command: String? = nil,
        terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot,
        useCustomIO: Bool = false
    ) {
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command
        self.terminalAccessoryInputSnapshot = terminalAccessoryInputSnapshot
        self.useCustomIO = useCustomIO

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : CGRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)
        // The default guide collapses undocked/floating keyboards to the
        // bottom safe area. Track their real frame so stale docked geometry
        // can be rejected during floating/full transitions.
        keyboardLayoutGuide.followsUndockedKeyboard = true

        // Set content scale factor for retina rendering (important before surface
        // creation). Avoid UIScreen.main (stale instance risk on iOS 26); the
        // window's screen scale is applied again in didMoveToWindow.
        self.contentScaleFactor = max(UITraitCollection.current.displayScale, 1)

        setupSurface()
        addSubview(imeProxyTextView)
        zoomIndicatorView.isHidden = true
        zoomIndicatorView.alpha = 0
        zoomIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomIndicatorView)
        NSLayoutConstraint.activate([
            zoomIndicatorView.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomIndicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomIndicatorView.widthAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumWidth),
            zoomIndicatorView.heightAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumHeight)
        ])
        nativeFindOverlay.frame = bounds
        addSubview(nativeFindOverlay)

        // Setup gesture recognizers with delegate for simultaneous recognition
        directTouchTapRecognizer.delegate = self
        scrollRecognizer.delegate = self
        pinchRecognizer.delegate = self
        directTouchTapRecognizer.require(toFail: nativeSelectionLongPressRecognizer)
        addGestureRecognizer(nativeSelectionLongPressRecognizer)
        imeProxyTextView.addGestureRecognizer(directTouchTapRecognizer)
        addGestureRecognizer(scrollRecognizer)
        addGestureRecognizer(pointerHoverRecognizer)
        addGestureRecognizer(pinchRecognizer)
        isUserInteractionEnabled = true

        setupNativeTextSelectionInteractions()
        setupNativeFindInteraction()
        let editMenuInteraction = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenuInteraction)
        self.editMenuInteraction = editMenuInteraction

        setupConfigReloadObservation()
        setupInputModeObservation()
        registerColorSchemeObserver()
        setupHardwareKeyboardObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    isolated deinit {
        cleanup()
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this in dismantleUIView to ensure proper cleanup.

    // MARK: - Layer Type
    // On iOS, Ghostty adds its own IOSurfaceLayer as a sublayer of the view's
    // existing CALayer. Keep the default layer type to avoid CAMetalLayer
    // interfering with sublayer rendering/compositing.




    // MARK: - UIView Overrides

    var acceptsTerminalInput = true {
        didSet {
            if !acceptsTerminalInput {
                cancelTrackedHardwareInput()
            }
        }
    }
    var keyboardFocusPolicy = TerminalKeyboardFocusPolicy()
    var suppressDirectTouchKeyboardFocusUntil = Date.distantPast
    var suppressAccessoryForMissingSoftwareKeyboard = false
    let hiddenKeyboardInputView = TerminalSuppressedKeyboardInputView()
    #if DEBUG
    enum KeyboardUITestSoftwareKeyboardFailure: Equatable {
        case none
        case untilSessionRebuild
    }

    var keyboardHideRequestCount = 0
    var keyboardInputSessionRebuildCount = 0
    var keyboardInputViewReloadCount = 0
    var keyboardUITestHardwareKeyboardOverride: Bool?
    var keyboardUITestSoftwareKeyboardFailure = KeyboardUITestSoftwareKeyboardFailure.none
    #endif
    var onWindowAttachmentChange: ((Bool) -> Void)?
    /// Reports terminal touches; isFocusTap is true for the plain
    /// tap-to-focus gesture, which also restores a user-hidden keyboard.
    var onTerminalDirectTouch: ((_ isFocusTap: Bool) -> Void)?
    var onKeyboardBrowseModeChange: ((Bool) -> Void)?
    var onKeyboardAccessoryHideRequested: (() -> Void)?
    var onFindNavigatorVisibilityChange: ((Bool) -> Void)?
    var findNavigatorLifecycle = TerminalFindNavigatorLifecycle()

    // MARK: - Scroll Gesture

    /// Scroll speed multiplier for iOS touch scrolling
    static let scrollMultiplier: Double = 1.5
    static let selectionAutoscrollEdgeInset: Double = 56
    static let selectionAutoscrollMaximumDelta: Double = 12

    /// Momentum deceleration rate (0.0-1.0, higher = slower deceleration)
    static let momentumDeceleration: Double = 0.92

    /// Minimum velocity to trigger momentum scrolling
    static let minimumMomentumVelocity: Double = 50.0

    /// Display link for momentum animation
    var momentumDisplayLink: CADisplayLink?
    var momentumVelocity: CGPoint = .zero
    var momentumPhase: Ghostty.Input.Momentum = .none
    var selectionAutoscrollDisplayLink: CADisplayLink?
    var selectionAutoscrollLocation: CGPoint?
    var selectionAutoscrollMods: Ghostty.Input.Mods = []

}

#endif
