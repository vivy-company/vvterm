#if os(iOS)
import Combine
import Foundation
import SwiftUI
import UIKit

nonisolated enum TerminalRenderingTransition: Equatable, Sendable {
    case none
    case pause
    case resume
}

nonisolated enum TerminalRenderingPolicy {
    static func transition(
        terminalIsActive: Bool,
        sceneIsActive: Bool,
        renderingIsPaused: Bool
    ) -> TerminalRenderingTransition {
        if terminalIsActive && sceneIsActive {
            return renderingIsPaused ? .resume : .none
        }
        return renderingIsPaused ? .none : .pause
    }
}

extension View {
    func terminalCommandFocusValues(
        activeServerId: UUID?,
        activePaneId: UUID?,
        splitActions: TerminalSplitActions?
    ) -> some View {
        self
    }

    func terminalKeyboardAvoidance(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalSurfaceChange: TerminalSurfaceStoreChange?,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?,
        keyboardCoordinator: TerminalKeyboardCoordinator,
        enabledOverride: Bool? = nil
    ) -> some View {
        modifier(
            TerminalKeyboardAvoidanceModifier(
                focusedPaneId: focusedPaneId,
                paneIds: paneIds,
                terminalSurfaceChange: terminalSurfaceChange,
                terminalProvider: terminalProvider,
                keyboardCoordinator: keyboardCoordinator,
                enabledOverride: enabledOverride
            )
        )
    }
}

@MainActor
private final class TerminalKeyboardAvoidanceViewModel: ObservableObject {
    private struct BaseGeometry {
        let windowIdentifier: ObjectIdentifier
        let boundsFrame: CGRect
        let terminalFrame: CGRect
    }

    @Published private(set) var layout = TerminalKeyboardAvoidancePolicy.Layout.unobstructed

    private weak var terminal: GhosttyTerminalView?
    private var keyboardFrame: CGRect?
    private var cursorRect: CGRect = .zero
    private var preservesTerminalSize = false
    private var baseGeometry: BaseGeometry?

    func update(
        preservesTerminalSize: Bool,
        terminal newTerminal: GhosttyTerminalView?,
        keyboardFrame: CGRect?,
        animation: Animation?
    ) {
        self.keyboardFrame = keyboardFrame
        self.preservesTerminalSize = preservesTerminalSize

        guard let newTerminal else {
            detachTerminal()
            setLayout(.unobstructed, animation: animation)
            return
        }

        if terminal !== newTerminal {
            detachTerminal()
            terminal = newTerminal
            newTerminal.onKeyboardAvoidanceCursorRectChange = { [weak self, weak newTerminal] cursorRect in
                guard let self, let newTerminal, self.terminal === newTerminal else { return }
                self.cursorRect = cursorRect
                self.recalculate(animation: .easeOut(duration: 0.12))
            }
            newTerminal.onKeyboardAvoidanceAccessoryFrameChange = { [weak self, weak newTerminal] in
                DispatchQueue.main.async {
                    guard let self, let newTerminal, self.terminal === newTerminal else { return }
                    self.recalculate(animation: .easeOut(duration: 0.12))
                }
            }
        }

        cursorRect = newTerminal.keyboardAvoidanceCursorRect()
        recalculate(animation: animation)
    }

    func detach() {
        detachTerminal()
        layout = .unobstructed
    }

    private func detachTerminal() {
        terminal?.disableKeyboardAvoidanceSizePreservation()
        terminal?.onKeyboardAvoidanceCursorRectChange = nil
        terminal?.onKeyboardAvoidanceAccessoryFrameChange = nil
        terminal = nil
        cursorRect = .zero
        baseGeometry = nil
    }

    private func recalculate(animation: Animation?) {
        guard let terminal, let window = terminal.window else {
            setLayout(.unobstructed, animation: animation)
            return
        }

        let currentBoundsFrame = terminal.convert(terminal.bounds, to: window)
        var resolvedBaseBoundsFrame = currentBoundsFrame.offsetBy(
            dx: 0,
            dy: -layout.verticalOffset
        )
        resolvedBaseBoundsFrame.size.height += layout.bottomInset
        let currentTerminalFrame = terminal.convert(
            terminal.keyboardAvoidanceTerminalRect(),
            to: window
        )
        var resolvedBaseTerminalFrame = currentTerminalFrame.offsetBy(
            dx: 0,
            dy: -layout.verticalOffset
        )
        resolvedBaseTerminalFrame.size.height += layout.bottomInset

        let windowIdentifier = ObjectIdentifier(window)
        let windowChanged = baseGeometry?.windowIdentifier != windowIdentifier
        let sizeChanged = baseGeometry.map {
            abs($0.boundsFrame.width - resolvedBaseBoundsFrame.width) >= 0.5
                || abs($0.boundsFrame.height - resolvedBaseBoundsFrame.height) >= 0.5
        } ?? true
        let unobstructed = keyboardFrame == nil && layout == .unobstructed
        if windowChanged
            || sizeChanged
            || unobstructed
            || baseGeometry == nil {
            baseGeometry = BaseGeometry(
                windowIdentifier: windowIdentifier,
                boundsFrame: resolvedBaseBoundsFrame,
                terminalFrame: resolvedBaseTerminalFrame
            )
        }
        guard let baseGeometry else { return }

        let keyboardFrameInWindow = keyboardFrame.map {
            window.convert($0, from: window.screen.coordinateSpace)
        }
        let accessoryFrameInWindow = terminal.keyboardAvoidanceAccessoryFrame().map {
            window.convert($0, from: window.screen.coordinateSpace)
        }
        let screenFrameInWindow = window.convert(
            window.screen.bounds,
            from: window.screen.coordinateSpace
        )
        let geometry = TerminalKeyboardAvoidancePolicy.resolvedGeometry(
            screenFrame: screenFrameInWindow,
            terminalFrame: baseGeometry.boundsFrame,
            keyboardFrame: keyboardFrameInWindow
        )
        let currentCursorFrame = terminal.convert(cursorRect, to: window)
        let baseCursorFrame = currentCursorFrame.offsetBy(
            dx: 0,
            dy: -layout.verticalOffset
        )
        let newLayout = TerminalKeyboardAvoidancePolicy.layout(
            preservesTerminalSize: preservesTerminalSize,
            geometry: geometry,
            terminalFrame: baseGeometry.terminalFrame,
            cursorFrame: baseCursorFrame,
            accessoryFrame: accessoryFrameInWindow
        )
        terminal.setKeyboardAvoidanceSizePreservationEnabled(
            newLayout.preservesTerminalSurfaceSize
        )
        setLayout(newLayout, animation: animation)
    }

    private func setLayout(
        _ newValue: TerminalKeyboardAvoidancePolicy.Layout,
        animation: Animation?
    ) {
        guard abs(layout.bottomInset - newValue.bottomInset) >= 0.5
                || abs(layout.verticalOffset - newValue.verticalOffset) >= 0.5
                || layout.preservesTerminalSurfaceSize != newValue.preservesTerminalSurfaceSize else {
            return
        }
        if let animation {
            withAnimation(animation) {
                layout = newValue
            }
        } else {
            layout = newValue
        }
    }
}

private struct TerminalKeyboardAvoidanceModifier: ViewModifier {
    let focusedPaneId: UUID?
    let paneIds: [UUID]
    let terminalSurfaceChange: TerminalSurfaceStoreChange?
    let terminalProvider: (UUID) -> GhosttyTerminalView?
    let enabledOverride: Bool?

    @AppStorage(TerminalDefaults.preserveTerminalSizeForKeyboardKey) private var storedEnabled = false
    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @StateObject private var model = TerminalKeyboardAvoidanceViewModel()

    init(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalSurfaceChange: TerminalSurfaceStoreChange?,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?,
        keyboardCoordinator: TerminalKeyboardCoordinator,
        enabledOverride: Bool?
    ) {
        self.focusedPaneId = focusedPaneId
        self.paneIds = paneIds
        self.terminalSurfaceChange = terminalSurfaceChange
        self.terminalProvider = terminalProvider
        self.enabledOverride = enabledOverride
        _keyboardCoordinator = ObservedObject(wrappedValue: keyboardCoordinator)
    }

    private var preservesTerminalSize: Bool {
        enabledOverride ?? storedEnabled
    }

    func body(content: Content) -> some View {
        content
            .padding(.bottom, preservesTerminalSize ? model.layout.bottomInset : 0)
            .offset(y: preservesTerminalSize ? model.layout.verticalOffset : 0)
            .clipped()
            .modifier(
                TerminalKeyboardSafeAreaModifier(
                    isEnabled: preservesTerminalSize
                )
            )
            .onAppear {
                refresh(animation: nil)
            }
            .onDisappear {
                for paneId in paneIds {
                    terminalProvider(paneId)?.onKeyboardAvoidanceCursorRectChange = nil
                    terminalProvider(paneId)?.onKeyboardAvoidanceAccessoryFrameChange = nil
                }
                model.detach()
            }
            .onChange(of: preservesTerminalSize) { _ in
                refresh(animation: keyboardAnimation)
            }
            .onChange(of: focusedPaneId) { _ in
                refresh(animation: .easeOut(duration: 0.12))
            }
            .onChange(of: terminalSurfaceChange) { _ in
                refresh(animation: nil)
            }
            .onChange(of: keyboardCoordinator.softwareKeyboardEndFrame) { _ in
                refresh(animation: keyboardAnimation)
            }
    }

    private var keyboardAnimation: Animation {
        let duration = keyboardCoordinator.keyboardAnimationDuration
        switch keyboardCoordinator.keyboardAnimationCurve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        }
    }

    private func refresh(animation: Animation?) {
        let terminal = focusedPaneId.flatMap(terminalProvider)
        model.update(
            preservesTerminalSize: preservesTerminalSize,
            terminal: terminal,
            keyboardFrame: keyboardCoordinator.softwareKeyboardEndFrame,
            animation: animation
        )
    }
}

/// Wraps a remote connection and Ghostty terminal for a pane on iOS/iPadOS.
struct RemoteTerminalPaneWrapper: View {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let tabManager: TerminalTabManager
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onPaneKeyboardShortcut: (TerminalSplitCommand) -> Void
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let onVoiceTrigger: (() -> Void)?
    let onSceneActivation: () -> Void

    @EnvironmentObject private var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    @AppStorage("terminalKeyboardDismissButtonEnabled") private var keyboardDismissButtonEnabled = true

    private var terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot {
        TerminalAccessoryInputSnapshot(
            profile: terminalAccessoryPreferencesManager.profile,
            showsDismissKeyboardButton: keyboardDismissButtonEnabled
        )
    }

    var body: some View {
        GeometryReader { geometry in
            RemoteTerminalPaneRepresentable(
                paneId: paneId,
                server: server,
                credentials: credentials,
                tabManager: tabManager,
                size: geometry.size,
                isActive: isActive,
                terminalContextMenuActions: terminalContextMenuActions,
                onPaneKeyboardShortcut: onPaneKeyboardShortcut,
                onProcessExit: onProcessExit,
                onReady: onReady,
                terminalAccessoryInputSnapshot: terminalAccessoryInputSnapshot,
                onVoiceTrigger: onVoiceTrigger
            )
            .background {
                TerminalSceneActivationObserver(
                    onSceneActivation: handleSceneActivation
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func handleSceneActivation(_ activatedScene: UIScene) {
        // A SwiftUI wrapper can briefly outlive registry ownership. Never let
        // that stale wrapper resume or reconnect a terminal now hosted by
        // another scene.
        guard let terminal = tabManager.terminalSurfaceStore.ghosttySurface(for: paneId),
              let terminalScene = terminal.window?.windowScene,
              terminalScene === activatedScene else { return }

        if TerminalRenderingPolicy.transition(
            terminalIsActive: isActive,
            sceneIsActive: terminalScene.activationState == .foregroundActive,
            renderingIsPaused: terminal.isRenderingPaused
        ) == .resume {
            terminal.resumeRendering()
        }
        onSceneActivation()
    }
}

private struct TerminalSceneActivationObserver: UIViewRepresentable {
    let onSceneActivation: (UIScene) -> Void

    func makeUIView(context: Context) -> TerminalSceneActivationView {
        TerminalSceneActivationView(onSceneActivation: onSceneActivation)
    }

    func updateUIView(_ view: TerminalSceneActivationView, context: Context) {
        view.onSceneActivation = onSceneActivation
    }
}

private final class TerminalSceneActivationView: UIView {
    var onSceneActivation: (UIScene) -> Void

    init(onSceneActivation: @escaping (UIScene) -> Void) {
        self.onSceneActivation = onSceneActivation
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let activatedScene = notification.object as? UIScene,
              activatedScene === window?.windowScene else { return }
        Task { @MainActor [weak self, weak activatedScene] in
            guard let self, let activatedScene,
                  activatedScene === self.window?.windowScene else { return }
            self.onSceneActivation(activatedScene)
        }
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private struct RemoteTerminalPaneRepresentable: UIViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let tabManager: TerminalTabManager
    let size: CGSize
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onPaneKeyboardShortcut: (TerminalSplitCommand) -> Void
    let onProcessExit: () -> Void
    let onReady: () -> Void
    let terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot
    let onVoiceTrigger: (() -> Void)?

    @EnvironmentObject var ghosttyApp: GhosttyRuntime
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> TerminalPaneConnectionCoordinator {
        TerminalPaneConnectionCoordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            tabManager: tabManager,
            sshFailureOutput: { failure in
                TerminalConnectionFailurePresentation.ansiSSHErrorData(for: failure)
            }
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator

        if let existingTerminal = tabManager.terminalSurfaceStore.ghosttySurface(for: paneId) {
            coordinator.terminal = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preservePane = true
            configureExistingTerminal(existingTerminal, coordinator: coordinator)
            existingTerminal.acceptsTerminalInput = isActive

            if existingTerminal.superview != nil {
                existingTerminal.removeFromSuperview()
            }
            if size.width > 0 && size.height > 0 {
                coordinator.lastReportedSize = size
                existingTerminal.frame = CGRect(origin: .zero, size: size)
                existingTerminal.sizeDidChange(size)
            }

            DispatchQueue.main.async {
                onReady()
                startConnectionIfNeeded(
                    terminal: existingTerminal,
                    coordinator: coordinator,
                    state: tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
                )
            }
            return existingTerminal
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            terminalAccessoryInputSnapshot: terminalAccessoryInputSnapshot,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            guard let coordinator else { return }
            DispatchQueue.main.async {
                coordinator.isTerminalReady = true
                onReady()
                if let terminalView {
                    startConnectionIfNeeded(
                        terminal: terminalView,
                        coordinator: coordinator,
                        state: tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
                    )
                }
            }
        }
        terminalView.onProcessExit = processExitHandler(for: terminalView)
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminalView.onTitleChange = { [paneId] title in
            tabManager.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            tabManager.handleTerminalZoom(action, for: paneId)
        }
        terminalView.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        terminalView.applyPresentationOverrides(
            tabManager.sessionState.presentationOverrides(for: paneId)
        )

        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        tabManager.registerTerminalSurface(terminalView, for: paneId)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToTransport(data)
        }
        terminalView.setupWriteCallback()
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }

        coordinator.lastReportedSize = initialSize
        if size.width > 0 && size.height > 0 {
            terminalView.sizeDidChange(size)
        }
        if !isActive {
            terminalView.pauseRendering()
        }

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView else {
            return
        }

        guard tabManager.sessionState.paneState(for: paneId) != nil else {
            terminalView.acceptsTerminalInput = false
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            terminalView.onVoiceButtonTapped = nil
            terminalView.onPaneKeyboardShortcut = nil
            return
        }

        let windowScene = terminalView.window?.windowScene
        let windowSceneIsActive = windowScene.map {
            $0.activationState == .foregroundActive
        }
        let sceneIsActive = TerminalSceneActivityPolicy.isActive(
            environmentIsActive: scenePhase == .active,
            windowSceneIsActive: windowSceneIsActive
        )
        let renderingTransition = TerminalRenderingPolicy.transition(
            terminalIsActive: isActive,
            sceneIsActive: sceneIsActive,
            renderingIsPaused: terminalView.isRenderingPaused
        )

        terminalView.acceptsTerminalInput = isActive
        let presentationOverrides = tabManager.sessionState.presentationOverrides(for: paneId)
        if terminalView.surfacePresentationOverrides != presentationOverrides {
            terminalView.applyPresentationOverrides(presentationOverrides)
        }
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.applyTerminalAccessoryInputSnapshot(terminalAccessoryInputSnapshot)
        terminalView.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        if size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            switch renderingTransition {
            case .resume:
                terminalView.resumeRendering()
            case .pause:
                terminalView.pauseRendering()
            case .none:
                break
            }
        }

        let state = tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
        let shouldStartConnection = TerminalConnectionStartPolicy.shouldStart(
            connectionState: state
        )

        if shouldStartConnection {
            startConnectionIfNeeded(
                terminal: terminalView,
                coordinator: context.coordinator,
                state: state
            )
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }

        let paneStillExists = coordinator.tabManager.sessionState
            .paneState(for: coordinator.paneId) != nil
        if paneStillExists {
            terminalView.acceptsTerminalInput = false
            terminalView.pauseRendering()
            coordinator.preservePane = true
            return
        }

        coordinator.terminal = nil
        let paneId = coordinator.paneId
        Task { @MainActor in
            coordinator.tabManager.unregisterTerminalSurface(terminalView, for: paneId)
            coordinator.cancelConnection()
        }
    }

    private func configureExistingTerminal(_ terminal: GhosttyTerminalView, coordinator: TerminalPaneConnectionCoordinator) {
        terminal.onProcessExit = processExitHandler(for: terminal)
        terminal.onVoiceButtonTapped = onVoiceTrigger
        terminal.applyTerminalAccessoryInputSnapshot(terminalAccessoryInputSnapshot)
        terminal.onPwdChange = { [paneId] rawDirectory in
            DispatchQueue.main.async {
                tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
        }
        terminal.onTitleChange = { [paneId] title in
            tabManager.updatePaneTitle(paneId, rawTitle: title)
        }
        terminal.onZoomAction = { [paneId] action in
            tabManager.handleTerminalZoom(action, for: paneId)
        }
        terminal.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        terminal.terminalContextMenuActions = terminalContextMenuActions
        terminal.applyPresentationOverrides(
            tabManager.sessionState.presentationOverrides(for: paneId)
        )
        terminal.writeCallback = { [weak coordinator] data in
            coordinator?.sendToTransport(data)
        }
        coordinator.installRichPasteInterception(on: terminal)
        terminal.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }
    }

    private func processExitHandler(for terminal: GhosttyTerminalView) -> () -> Void {
        { [weak terminal] in
            guard let terminal,
                  tabManager.terminalSurfaceStore.isRegistered(
                    terminal,
                    for: paneId
                  ) else { return }
            onProcessExit()
        }
    }

    private func startConnectionIfNeeded(
        terminal: GhosttyTerminalView,
        coordinator: TerminalPaneConnectionCoordinator,
        state: ConnectionState
    ) {
        guard tabManager.sessionState.paneState(for: paneId) != nil else { return }
        guard !coordinator.hasLiveConnection else { return }
        guard !coordinator.isConnectionStartInFlight else { return }
        guard tabManager.reconnectCoordinator.applicationActivityIsActive else { return }

        switch state {
        case .connecting, .reconnecting, .connected:
            break
        case .disconnected, .failed, .idle:
            return
        }

        coordinator.startConnection(terminal: terminal)
    }
}
#endif
