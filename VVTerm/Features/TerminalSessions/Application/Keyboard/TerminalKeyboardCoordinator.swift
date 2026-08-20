import CoreGraphics
import Foundation

struct TerminalKeyboardSyncScheduler: Equatable {
    enum Phase: Equatable {
        case idle(lastReason: String)
        case scheduled(reason: String)
        case syncing(reason: String, pendingReason: String?)
    }

    private(set) var phase = Phase.idle(lastReason: "initial")

    var reason: String {
        switch phase {
        case .idle(let reason), .scheduled(let reason):
            reason
        case .syncing(let reason, let pendingReason):
            pendingReason ?? reason
        }
    }

    mutating func request(reason: String) -> Bool {
        switch phase {
        case .idle:
            phase = .scheduled(reason: reason)
            return true
        case .scheduled:
            phase = .scheduled(reason: reason)
            return false
        case .syncing(let activeReason, _):
            phase = .syncing(reason: activeReason, pendingReason: reason)
            return false
        }
    }

    mutating func beginSync() -> String? {
        guard case .scheduled(let reason) = phase else { return nil }
        phase = .syncing(reason: reason, pendingReason: nil)
        return reason
    }

    mutating func finishSync() -> Bool {
        guard case .syncing(let reason, let pendingReason) = phase else { return false }
        if pendingReason != nil {
            phase = .scheduled(reason: "coalescedResync")
            return true
        }
        phase = .idle(lastReason: reason)
        return false
    }

    mutating func cancel(reason: String) {
        phase = .idle(lastReason: reason)
    }
}

#if os(iOS)
import Combine
import os.log

@MainActor
protocol TerminalKeyboardInputSession: AnyObject {
    func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot
    @discardableResult
    func acquireTerminalInput() -> Bool
    @discardableResult
    func forceSoftwareKeyboardInput() -> Bool
    @discardableResult
    func focusTerminalInputWithoutShowingSoftwareKeyboard() -> Bool
    func releaseTerminalInput()
    func releaseTerminalInputForReacquisition(completion: @escaping () -> Void)
    func setTerminalInputAccessorySuppressed(_ suppressed: Bool)
    func refreshTerminalInputAccessoryAppearance()
}

/// Owns the terminal text-input session and observes what UIKit actually
/// does with it. The design rule that keeps this correct: the app CONTROLS
/// only the session (first responder) from app state; whether a software
/// keyboard is on screen is OBSERVED from keyboard frame notifications and
/// never predicted. There is deliberately no hardware-keyboard detection:
/// iOS decides whether to present the software keyboard for an active
/// session (it knows about attached keyboards and iPhone Mirroring
/// authoritatively). When UIKit accepts the responder but reports no real
/// software-keyboard frame, the terminal hides its input accessory so the
/// user never gets a long-lived bar without a keyboard.
@MainActor
final class TerminalKeyboardCoordinator: ObservableObject {
    /// UIKit responder ownership is separate from durable typing intent. Every
    /// transition creates a new generation so delayed verification or rebuild
    /// work can never revive a responder session that another app now owns.
    private enum InputOwnership: Equatable {
        case available(generation: UUID)
        case local(generation: UUID)
        case external(generation: UUID)

        var generation: UUID {
            switch self {
            case .available(let generation),
                 .local(let generation),
                 .external(let generation):
                generation
            }
        }

        var allowsLocalAcquisition: Bool {
            if case .external = self {
                return false
            }
            return true
        }
    }

    private enum PresentationVerificationLayoutSource {
        case currentLayoutFrame
        case observedEventsOnly

        var reconcilesLayoutFrameAtDeadline: Bool {
            self == .currentLayoutFrame
        }
    }

    enum ImmediateDeactivationReason: String {
        case contentProtection
        case routeModal
    }

    nonisolated enum PresentationRefreshAction: Equatable, Sendable {
        case none
        case deferUntilVerification
        case rebuild
    }

    nonisolated enum SoftwareKeyboardPresentation: Equatable {
        case hidden
        case docked(frame: CGRect)
        case floating(frame: CGRect)

        var frame: CGRect? {
            switch self {
            case .hidden:
                nil
            case .docked(let frame), .floating(let frame):
                frame
            }
        }

        var isVisible: Bool {
            frame != nil
        }
    }

    private enum PresentationRequest: Equatable {
        case none
        case automaticRefresh
        case contentProtectionRecovery
        case forceSoftwareKeyboard(repairActiveSession: Bool)

        var isExplicitSoftwareKeyboardRequest: Bool {
            if case .forceSoftwareKeyboard = self {
                return true
            }
            return false
        }

        var waitsForWindowOwnership: Bool {
            switch self {
            case .contentProtectionRecovery, .forceSoftwareKeyboard:
                return true
            case .none, .automaticRefresh:
                return false
            }
        }
    }

    private enum ContentProtectionRecoveryState: Equatable {
        case idle
        case pending(paneId: UUID)
        case recovering(paneId: UUID)

        func isPending(for paneId: UUID) -> Bool {
            self == .pending(paneId: paneId)
        }
    }

    private enum FindNavigatorState: Equatable {
        case inactive
        case active(terminalKeyboardWasMissing: Bool)
        /// Find can disappear while its last keyboard frame remains visible.
        /// Keep the pre-Find failure scoped to this terminal until the user's
        /// Keyboard command performs one real responder-session rebuild.
        case terminalRepairPending

        var isActive: Bool {
            if case .active = self {
                return true
            }
            return false
        }

        var requiresTerminalRepair: Bool {
            switch self {
            case .active(terminalKeyboardWasMissing: true), .terminalRepairPending:
                return true
            case .inactive, .active(terminalKeyboardWasMissing: false):
                return false
            }
        }
    }

    private struct ExplicitPresentationRecovery: Equatable {
        enum Phase: Equatable {
            case rebuilding
            case waitingForActivation
        }

        let paneId: UUID
        let terminalIdentifier: ObjectIdentifier
        var phase: Phase
    }

    struct StateInputs: Equatable {
        var viewActive: Bool
        var activePaneInputEligible: Bool
        var activePaneWindowAttached: Bool
        var allowsLocalInputOwnership: Bool
        var userHidKeyboard: Bool
        var findNavigatorActive: Bool
    }

    @Published private(set) var isUserHidden = false
    /// One source of truth for software-keyboard visibility and geometry.
    /// Layout consumers convert the associated screen-space frame into their
    /// own window before using it.
    @Published private(set) var softwareKeyboardPresentation = SoftwareKeyboardPresentation.hidden
    var isSoftwareKeyboardVisible: Bool {
        softwareKeyboardPresentation.isVisible
    }
    var softwareKeyboardEndFrame: CGRect? {
        softwareKeyboardPresentation.frame
    }
    private(set) var keyboardAnimationDuration: TimeInterval = 0.25
    private(set) var keyboardAnimationCurve = TerminalKeyboardAnimationCurve.easeInOut

    var terminalProvider: ((UUID) -> (any TerminalKeyboardInputSession)?)?

    private var activePaneId: UUID?
    private var viewActive = false
    private var paneInputEligibleById: [UUID: Bool] = [:]
    private var paneWindowAttachedById: [UUID: Bool] = [:]
    private var findNavigatorState = FindNavigatorState.inactive
    private var syncScheduler = TerminalKeyboardSyncScheduler()
    private var lastManagedPaneId: UUID?
    private var pendingPresentationRequest = PresentationRequest.none
    private var contentProtectionRecoveryState = ContentProtectionRecoveryState.idle
    private var explicitPresentationRecovery: ExplicitPresentationRecovery?
    private var presentationVerifyTask: Task<Void, Never>?
    private var activeTerminalSceneIsForeground = true
    private var inputOwnership = InputOwnership.available(generation: UUID())
    /// Rebuilding a session UIKit refuses to present cannot succeed by
    /// repetition; cap attempts until a keyboard actually shows (which
    /// resets the count).
    private var presentationRefreshAttemptCount = 0
    private let presentationRefreshAttemptLimit = 2
    /// An input assistant/shortcuts bar alone reports a small keyboard frame
    /// (~44-72pt); a real software keyboard is far taller on every device.
    private let softwareKeyboardMinimumHeight: CGFloat = 100
    private let keyboardEventSource: any TerminalKeyboardEventSource
    private let lifecycleLoggingEnabled: Bool

    init(
        keyboardEventSource: any TerminalKeyboardEventSource,
        lifecycleLoggingEnabled: Bool
    ) {
        self.keyboardEventSource = keyboardEventSource
        self.lifecycleLoggingEnabled = lifecycleLoggingEnabled
        keyboardEventSource.start { [weak self] event in
            self?.receive(event)
        }
    }

    isolated deinit {
        keyboardEventSource.stop()
    }

    private func receive(_ event: TerminalKeyboardEvent) {
        if let diagnostics = event.diagnostics {
            logKeyboardNotification(
                name: diagnostics.name,
                object: diagnostics.object,
                beginFrame: diagnostics.beginFrame,
                endFrame: diagnostics.endFrame,
                isLocal: event.isLocal,
                duration: event.animationDuration,
                curveRawValue: event.animationCurve?.rawValue
            )
        }

        switch event.kind {
        case .frameChanged(let frame):
            noteKeyboardEndFrame(
                frame,
                isLocal: event.isLocal,
                sourceScreenIdentifier: event.sourceScreenIdentifier,
                animationDuration: event.animationDuration,
                animationCurve: event.animationCurve
            )
        case .hidden:
            noteSoftwareKeyboardHidden(
                isLocal: event.isLocal,
                sourceScreenIdentifier: event.sourceScreenIdentifier,
                animationDuration: event.animationDuration,
                animationCurve: event.animationCurve
            )
        }
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "KeyboardCoordinator"
    )

    #if DEBUG
    nonisolated private static var usesUITestKeyboardFrameSimulation: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-simulate-keyboard-frames")
    }
    #endif

    /// Whether the terminal should hold the text-input session (first
    /// responder). Hardware keyboards and the user's software-keyboard hidden
    /// preference are irrelevant here: key events need an active responder
    /// either way, and UIKit decides on its own whether the session also
    /// presents a software keyboard.
    nonisolated static func desiredInputSessionActive(inputs: StateInputs) -> Bool {
        inputs.viewActive
            && inputs.activePaneInputEligible
            && inputs.activePaneWindowAttached
            && inputs.allowsLocalInputOwnership
            && !inputs.findNavigatorActive
    }

    /// A reconnecting pane may retain the existing input session only when
    /// the terminal recorded prior typing intent. This preserves responder
    /// ownership without making connection state and keyboard focus two
    /// competing sources of truth.
    nonisolated static func paneInputEligible(
        connectionState: ConnectionState,
        shouldRestoreOnReconnect: Bool
    ) -> Bool {
        switch connectionState {
        case .connected:
            return true
        case .connecting, .reconnecting:
            return shouldRestoreOnReconnect
        case .disconnected, .failed, .idle:
            return false
        }
    }

    nonisolated static func desiredKeyboardVisible(inputs: StateInputs) -> Bool {
        desiredInputSessionActive(inputs: inputs)
            && !inputs.userHidKeyboard
    }

    nonisolated static func presentationRefreshAction(
        keyboardPresentationDesired: Bool,
        refreshRequested: Bool,
        windowOwnsInput: Bool,
        softwareInputActive: Bool,
        softwareKeyboardSuppressed: Bool,
        softwareKeyboardVisible: Bool,
        presentationVerificationPending: Bool,
        refreshAttemptCount: Int,
        refreshAttemptLimit: Int
    ) -> PresentationRefreshAction {
        guard keyboardPresentationDesired,
              refreshRequested,
              windowOwnsInput,
              softwareInputActive,
              !softwareKeyboardSuppressed,
              !softwareKeyboardVisible,
              refreshAttemptCount < refreshAttemptLimit else {
            return .none
        }
        return presentationVerificationPending ? .deferUntilVerification : .rebuild
    }

    nonisolated static func visibleKeyboardFrame(
        _ frame: CGRect?,
        in screenFrame: CGRect?,
        minimumHeight: CGFloat = 100
    ) -> CGRect? {
        guard let frame,
              let screenFrame,
              !frame.isNull,
              !frame.isEmpty,
              !frame.isInfinite,
              !screenFrame.isNull,
              !screenFrame.isEmpty,
              !screenFrame.isInfinite else {
            return nil
        }
        let overlap = screenFrame.intersection(frame)
        guard !overlap.isNull, overlap.height >= max(minimumHeight, 0) else {
            return nil
        }
        return frame
    }

    nonisolated static func softwareKeyboardPresentation(
        for frame: CGRect?,
        in screenFrame: CGRect?,
        minimumHeight: CGFloat = 100
    ) -> SoftwareKeyboardPresentation {
        guard let visibleFrame = visibleKeyboardFrame(
            frame,
            in: screenFrame,
            minimumHeight: minimumHeight
        ), let screenFrame else {
            return .hidden
        }

        let overlap = screenFrame.intersection(visibleFrame)
        let edgeTolerance: CGFloat = 1
        let fillsBottomEdge = abs(overlap.maxY - screenFrame.maxY) <= edgeTolerance
        let fillsWidth = abs(overlap.minX - screenFrame.minX) <= edgeTolerance
            && abs(overlap.maxX - screenFrame.maxX) <= edgeTolerance
        return fillsBottomEdge && fillsWidth
            ? .docked(frame: visibleFrame)
            : .floating(frame: visibleFrame)
    }

    nonisolated static func keyboardNotificationMatchesActiveScreen(
        sourceScreenIdentifier: ObjectIdentifier?,
        activeScreenIdentifier: ObjectIdentifier?
    ) -> Bool {
        guard let sourceScreenIdentifier else {
            // Keyboard notification objects were nil before iOS 16.1.
            return true
        }
        return sourceScreenIdentifier == activeScreenIdentifier
    }

    func setActivePane(_ paneId: UUID?) {
        guard activePaneId != paneId else { return }
        invalidateInputOwnershipGeneration()
        cancelPresentationVerify()
        // Presentation requests belong to the pane that was active when the
        // interaction occurred. A tab change must not transfer an explicit
        // software-keyboard command (or a stale automatic repair) elsewhere.
        pendingPresentationRequest = .none
        presentationRefreshAttemptCount = 0
        findNavigatorState = .inactive
        if let paneId,
           explicitPresentationRecovery?.paneId != paneId {
            explicitPresentationRecovery = nil
        }
        activePaneId = paneId
        markDirty(reason: "activePane")
    }

    /// The pane identity can stay stable while SwiftUI replaces its platform
    /// terminal view. Reconcile that new input-session owner even when all
    /// published pane facts are unchanged, and discard repair work that was
    /// scoped to the terminal it replaced.
    func terminalProviderIdentityDidChange(for paneId: UUID) {
        if explicitPresentationRecovery?.paneId == paneId {
            explicitPresentationRecovery = nil
        }
        guard activePaneId == paneId else { return }
        invalidateInputOwnershipGeneration()
        cancelPresentationVerify()
        pendingPresentationRequest = .none
        presentationRefreshAttemptCount = 0
        findNavigatorState = .inactive
        markDirty(reason: "terminalProviderIdentityChanged")
    }

    func setViewActive(_ active: Bool) {
        if !active {
            cancelPresentationVerify()
            detachAccessoryAndClearSoftwareKeyboardObservation()
            findNavigatorState = .inactive
        }
        guard viewActive != active else { return }
        viewActive = active
        markDirty(reason: "viewActive")
    }

    func setPaneInputEligible(_ eligible: Bool, for paneId: UUID) {
        guard paneInputEligibleById[paneId] != eligible else { return }
        if !eligible, activePaneId == paneId {
            cancelPresentationVerify()
        }
        paneInputEligibleById[paneId] = eligible
        markDirty(reason: "paneInputEligible")
    }

    func removePane(_ paneId: UUID) {
        if explicitPresentationRecovery?.paneId == paneId {
            explicitPresentationRecovery = nil
        }
        switch contentProtectionRecoveryState {
        case .pending(let recoveryPaneId), .recovering(let recoveryPaneId):
            if recoveryPaneId == paneId {
                contentProtectionRecoveryState = .idle
            }
        case .idle:
            break
        }
        let didRemoveInputEligibility = paneInputEligibleById.removeValue(forKey: paneId) != nil
        let didRemoveWindow = paneWindowAttachedById.removeValue(forKey: paneId) != nil
        if activePaneId == paneId {
            cancelPresentationVerify()
            findNavigatorState = .inactive
            activePaneId = nil
            markDirty(reason: "removeActivePane")
        } else if didRemoveInputEligibility || didRemoveWindow {
            markDirty(reason: "removePane")
        }
    }

    /// Called only after the route verifies that the activated scene is the
    /// active terminal's own window scene. InputUI and other app scenes must
    /// not reset the repair budget or start a responder rebuild loop.
    func activeTerminalSceneDidActivate(for paneId: UUID) {
        guard activePaneId == paneId else { return }
        if !activeTerminalSceneIsForeground || !inputOwnership.allowsLocalAcquisition {
            makeLocalInputOwnershipAvailable()
        }
        activeTerminalSceneIsForeground = true
        presentationRefreshAttemptCount = 0
        if let terminal = activeTerminal {
            let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
            terminal.refreshTerminalInputAccessoryAppearance()
            guard snapshot.windowAttached, snapshot.windowIsKey else {
                markDirty(reason: "sceneActivatedWithoutInputOwnership")
                return
            }
            reconcileSoftwareKeyboardPresentation(
                terminal: terminal,
                snapshot: snapshot
            )
            if snapshot.isSoftwareInputActive,
               !snapshot.isSoftwareKeyboardSuppressed {
                if Self.desiredKeyboardVisible(inputs: currentInputs),
                   !isSoftwareKeyboardVisible {
                    schedulePresentationVerify(
                        for: paneId,
                        terminal: terminal,
                        retryRequest: .automaticRefresh
                    )
                }
            } else {
                requestAutomaticPresentationRefresh()
            }
        }
        markDirty(reason: "sceneActivated")
    }

    /// Content protection can finish after the scene and window activation
    /// notifications have already been delivered. Replay scene recovery and
    /// require one responder-free turn so stale InputUI ownership cannot make
    /// repeated `becomeFirstResponder()` calls fail without rebuilding.
    func activeTerminalContentDidBecomeVisible(for paneId: UUID) {
        guard contentProtectionRecoveryState.isPending(for: paneId),
              activePaneId == paneId,
              let terminal = activeTerminal else {
            return
        }
        contentProtectionRecoveryState = .recovering(paneId: paneId)
        let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
        if Self.desiredKeyboardVisible(inputs: currentInputs),
           !snapshot.isSoftwareKeyboardSuppressed {
            // Content protection suppresses the accessory before releasing
            // InputUI. Clear only that temporary suppression; an ordinary
            // scene activation must preserve its existing presentation state.
            terminal.setTerminalInputAccessorySuppressed(false)
        }
        activeTerminalSceneDidActivate(for: paneId)
        guard !isUserHidden else { return }
        guard !snapshot.isSoftwareKeyboardSuppressed else {
            if pendingPresentationRequest == .automaticRefresh {
                pendingPresentationRequest = .none
            }
            markDirty(reason: "contentProtectionEndedWithSoftwareKeyboardSuppressed")
            return
        }
        cancelPresentationVerify()
        presentationRefreshAttemptCount = 0
        pendingPresentationRequest = .contentProtectionRecovery
        markDirty(reason: "contentProtectionEnded")
    }

    func activeTerminalSceneWillDeactivate(for paneId: UUID) {
        guard activePaneId == paneId else { return }
        if contentProtectionRecoveryState == .recovering(paneId: paneId) {
            contentProtectionRecoveryState = .pending(paneId: paneId)
        }
        guard activeTerminalSceneIsForeground else { return }
        activeTerminalSceneIsForeground = false
        makeLocalInputOwnershipAvailable()
        cancelPresentationVerify()
        if pendingPresentationRequest == .automaticRefresh {
            pendingPresentationRequest = .none
        }
        explicitPresentationRecovery = nil
        clearSoftwareKeyboardObservation()
    }

    func activeTerminalWindowDidBecomeKey(for paneId: UUID) {
        guard activePaneId == paneId else { return }
        guard activeTerminalSceneIsForeground else { return }
        activeTerminalSceneDidActivate(for: paneId)
    }

    func setWindowAttached(_ attached: Bool, for paneId: UUID) {
        guard paneWindowAttachedById[paneId] != attached else { return }
        if !attached, activePaneId == paneId {
            cancelPresentationVerify()
        }
        paneWindowAttachedById[paneId] = attached
        markDirty(reason: "windowAttached")
    }

    func setFindNavigatorActive(_ active: Bool, for paneId: UUID) {
        guard activePaneId == paneId else { return }
        guard findNavigatorState.isActive != active else { return }
        if active {
            cancelPresentationVerify()
            let terminalKeyboardWasMissing = findNavigatorState.requiresTerminalRepair
                || (Self.desiredKeyboardVisible(inputs: currentInputs)
                    && !isSoftwareKeyboardVisible)
            findNavigatorState = .active(
                terminalKeyboardWasMissing: terminalKeyboardWasMissing
            )
        } else if case .active(let terminalKeyboardWasMissing) = findNavigatorState {
            findNavigatorState = terminalKeyboardWasMissing
                ? .terminalRepairPending
                : .inactive
        }
        markDirty(reason: "findNavigator")
    }

    /// Removes UIKit input ownership before a shield or route modal appears.
    /// A scheduled reconciliation can run too late because the keyboard
    /// belongs to a separate system scene.
    func deactivateInputImmediately(
        reason: ImmediateDeactivationReason = .contentProtection
    ) {
        if case .contentProtection = reason,
           let paneId = activePaneId ?? lastManagedPaneId {
            contentProtectionRecoveryState = .pending(paneId: paneId)
        }
        detachAccessoryAndClearSoftwareKeyboardObservation()
        pendingPresentationRequest = .none
        explicitPresentationRecovery = nil
        makeLocalInputOwnershipAvailable()
        guard activePaneId != nil
                || viewActive
                || findNavigatorState != .inactive
                || lastManagedPaneId != nil else {
            return
        }
        activePaneId = nil
        viewActive = false
        findNavigatorState = .inactive
        cancelPresentationVerify()
        syncImmediately(reason: reason.rawValue)
    }

    /// Navigation must not synchronously ask UIKit/InputUI to tear down its
    /// responder scene. SwiftUI removes the terminal from the window as part
    /// of the pop; forgetting coordinator ownership first prevents any queued
    /// reconciliation from calling `resignFirstResponder()` on the Back path.
    func relinquishRouteOwnershipForNavigation() {
        pendingPresentationRequest = .none
        contentProtectionRecoveryState = .idle
        explicitPresentationRecovery = nil
        activePaneId = nil
        viewActive = false
        findNavigatorState = .inactive
        lastManagedPaneId = nil
        makeLocalInputOwnershipAvailable()
        cancelPresentationVerify()
        softwareKeyboardPresentation = .hidden
        syncScheduler.cancel(reason: "routeNavigation")
    }

    func contentProtectionRecoveryIsPending(for paneId: UUID) -> Bool {
        contentProtectionRecoveryState.isPending(for: paneId)
    }

    func userRequestedHide() {
        pendingPresentationRequest = .none
        explicitPresentationRecovery = nil
        cancelPresentationVerify()
        // This is an explicit command, not an idempotent state reconciliation.
        // Republish even when the stored value is already true so a route whose
        // recovery controls missed an earlier update is forced to render them.
        isUserHidden = true
        markDirty(reason: "userHide")
    }

    func userRequestedShow() {
        claimLocalInputOwnershipForExplicitInteraction()
        logExplicitPresentationRequest()
        if explicitPresentationRecovery?.phase == .waitingForActivation {
            explicitPresentationRecovery = nil
        }
        let requiresFindRepair = findNavigatorState.requiresTerminalRepair
        let activeInputNeedsRepair = activeTerminal?
            .keyboardCoordinatorDiagnosticSnapshot()
            .isSoftwareInputActive == true
        pendingPresentationRequest = .forceSoftwareKeyboard(
            repairActiveSession: requiresFindRepair
                || (!isUserHidden && activeInputNeedsRepair)
        )
        // The repair cap stops AUTOMATIC rebuild loops (e.g. against a
        // hardware keyboard's legitimate suppression, which can exhaust it);
        // an explicit user action re-arms it, otherwise returning from
        // mirroring leaves taps unable to re-present the keyboard.
        presentationRefreshAttemptCount = 0
        if isUserHidden {
            isUserHidden = false
        }
        markDirty(reason: "userShow")
    }

    func directTouchOnTerminal(isFocusTap: Bool = false) {
        guard let terminal = activeTerminal else {
            return
        }
        let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
        guard activeTerminalSceneIsForeground,
              snapshot.windowAttached,
              snapshot.windowIsKey else {
            return
        }
        claimLocalInputOwnershipForExplicitInteraction()
        guard !isUserHidden, !isSoftwareKeyboardVisible else { return }
        requestAutomaticPresentationRefresh()
        // See userRequestedShow: user actions get a fresh repair budget.
        presentationRefreshAttemptCount = 0
        markDirty(reason: "directTouch")
    }

    private func claimLocalInputOwnershipForExplicitInteraction() {
        guard !inputOwnership.allowsLocalAcquisition,
              activeTerminalSceneIsForeground,
              let terminal = activeTerminal else {
            return
        }
        let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
        guard snapshot.windowAttached, snapshot.windowIsKey else { return }
        makeLocalInputOwnershipAvailable()
        markDirty(reason: "explicitLocalInteraction")
    }

    private func noteKeyboardEndFrame(
        _ frame: CGRect?,
        isLocal: Bool?,
        sourceScreenIdentifier: ObjectIdentifier?,
        animationDuration: TimeInterval?,
        animationCurve: TerminalKeyboardAnimationCurve?
    ) {
        guard isLocal != false else {
            noteExternalKeyboardOwnership()
            return
        }
        #if DEBUG
        guard !Self.usesUITestKeyboardFrameSimulation else { return }
        #endif
        guard Self.desiredKeyboardVisible(inputs: currentInputs) else {
            clearSoftwareKeyboardObservation()
            return
        }
        guard activeTerminalSceneIsForeground,
              inputOwnership.allowsLocalAcquisition,
              viewActive,
              let frame,
              let terminal = activeTerminal else {
            return
        }
        updateKeyboardAnimation(duration: animationDuration, curve: animationCurve)
        let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
        if snapshot.isSoftwareKeyboardSuppressed {
            setSoftwareKeyboardPresentation(.hidden, terminal: terminal)
            return
        }
        guard snapshot.windowAttached,
              snapshot.windowIsKey,
              snapshot.isSoftwareInputActive,
              Self.keyboardNotificationMatchesActiveScreen(
                  sourceScreenIdentifier: sourceScreenIdentifier,
                  activeScreenIdentifier: snapshot.screenIdentifier
              ) else {
            return
        }
        let presentation = Self.softwareKeyboardPresentation(
            for: frame,
            in: snapshot.screenFrame,
            minimumHeight: softwareKeyboardMinimumHeight
        )
        setSoftwareKeyboardPresentation(presentation, terminal: terminal)
    }

    private func noteSoftwareKeyboardHidden(
        isLocal: Bool?,
        sourceScreenIdentifier: ObjectIdentifier?,
        animationDuration: TimeInterval?,
        animationCurve: TerminalKeyboardAnimationCurve?
    ) {
        guard isLocal != false else {
            noteExternalKeyboardOwnership()
            return
        }
        #if DEBUG
        guard !Self.usesUITestKeyboardFrameSimulation else { return }
        #endif
        handleLocalSoftwareKeyboardHidden(
            sourceScreenIdentifier: sourceScreenIdentifier,
            animationDuration: animationDuration,
            animationCurve: animationCurve
        )
    }

    private func handleLocalSoftwareKeyboardHidden(
        sourceScreenIdentifier: ObjectIdentifier?,
        animationDuration: TimeInterval?,
        animationCurve: TerminalKeyboardAnimationCurve?
    ) {
        guard activeTerminalSceneIsForeground,
              inputOwnership.allowsLocalAcquisition else { return }
        updateKeyboardAnimation(duration: animationDuration, curve: animationCurve)
        if let terminal = activeTerminal {
            let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
            guard Self.keyboardNotificationMatchesActiveScreen(
                sourceScreenIdentifier: sourceScreenIdentifier,
                activeScreenIdentifier: snapshot.screenIdentifier
            ) else {
                return
            }
            if snapshot.isSoftwareKeyboardSuppressed {
                setSoftwareKeyboardPresentation(.hidden, terminal: terminal)
                return
            }
        }
        clearSoftwareKeyboardObservation()
        guard let paneId = activePaneId,
              let terminal = activeTerminal else { return }
        let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
        guard Self.desiredKeyboardVisible(inputs: currentInputs),
              snapshot.windowAttached,
              snapshot.windowIsKey,
              snapshot.isSoftwareInputActive,
              !snapshot.isSoftwareKeyboardSuppressed else { return }
        schedulePresentationVerify(
            for: paneId,
            terminal: terminal,
            layoutSource: .observedEventsOnly
        )
    }

    private func noteExternalKeyboardOwnership() {
        inputOwnership = .external(generation: UUID())
        cancelPresentationVerify()
        pendingPresentationRequest = .none
        explicitPresentationRecovery = nil
        clearSoftwareKeyboardObservation()
        releaseTerminalInputIfOwned()
        markDirty(reason: "externalInputOwnership")
    }

    private func clearSoftwareKeyboardObservation() {
        setSoftwareKeyboardPresentation(.hidden)
    }

    private func detachAccessoryAndClearSoftwareKeyboardObservation() {
        activeTerminal?.setTerminalInputAccessorySuppressed(true)
        clearSoftwareKeyboardObservation()
    }

    private func suppressAccessory(
        for terminal: any TerminalKeyboardInputSession
    ) {
        terminal.setTerminalInputAccessorySuppressed(true)
    }

    private func updateKeyboardAnimation(
        duration: TimeInterval?,
        curve: TerminalKeyboardAnimationCurve?
    ) {
        if let duration, duration > 0 {
            keyboardAnimationDuration = duration
        }
        if let curve {
            keyboardAnimationCurve = curve
        }
    }

    private func setSoftwareKeyboardPresentation(
        _ presentation: SoftwareKeyboardPresentation,
        terminal: (any TerminalKeyboardInputSession)? = nil
    ) {
        let terminal = terminal ?? activeTerminal
        if presentation.isVisible {
            cancelPresentationVerify()
            presentationRefreshAttemptCount = 0
            terminal?.setTerminalInputAccessorySuppressed(false)
        }
        guard softwareKeyboardPresentation != presentation else { return }
        softwareKeyboardPresentation = presentation
        markDirty(reason: presentation.isVisible ? "keyboardShown" : "keyboardHidden")
    }

    private func reconcileSoftwareKeyboardPresentation(
        terminal: any TerminalKeyboardInputSession,
        snapshot: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        #if DEBUG
        guard !Self.usesUITestKeyboardFrameSimulation else { return }
        #endif
        guard presentationVerifyTask == nil else { return }
        if snapshot.isSoftwareKeyboardSuppressed {
            setSoftwareKeyboardPresentation(.hidden, terminal: terminal)
            return
        }
        guard activeTerminalSceneIsForeground,
              Self.desiredKeyboardVisible(inputs: currentInputs),
              snapshot.windowAttached,
              snapshot.windowIsKey,
              snapshot.isSoftwareInputActive else {
            return
        }
        let presentation = Self.softwareKeyboardPresentation(
            for: snapshot.keyboardLayoutFrame,
            in: snapshot.screenFrame,
            minimumHeight: softwareKeyboardMinimumHeight
        )
        guard presentation.isVisible else { return }
        setSoftwareKeyboardPresentation(presentation, terminal: terminal)
    }

    private var activeTerminal: (any TerminalKeyboardInputSession)? {
        activePaneId.flatMap { terminalProvider?($0) }
    }

    private func makeLocalInputOwnershipAvailable() {
        inputOwnership = .available(generation: UUID())
    }

    private func invalidateInputOwnershipGeneration() {
        if inputOwnership.allowsLocalAcquisition {
            makeLocalInputOwnershipAvailable()
        } else {
            inputOwnership = .external(generation: UUID())
        }
    }

    private func releaseTerminalInputIfOwned() {
        guard let terminal = activeTerminal else { return }
        let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
        guard snapshot.isFirstResponder || snapshot.isSoftwareInputActive else { return }
        terminal.releaseTerminalInput()
    }

    private func recordLocalInputOwnershipIfNeeded(
        snapshot: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard activeTerminalSceneIsForeground,
              inputOwnership.allowsLocalAcquisition,
              snapshot.isFirstResponder || snapshot.isSoftwareInputActive else {
            return
        }
        let localOwnership = InputOwnership.local(generation: inputOwnership.generation)
        if inputOwnership != localOwnership {
            inputOwnership = localOwnership
        }
    }

    private func requestAutomaticPresentationRefresh() {
        guard explicitPresentationRecovery == nil,
              pendingPresentationRequest == .none else {
            return
        }
        pendingPresentationRequest = .automaticRefresh
    }

    private var currentInputs: StateInputs {
        let paneId = activePaneId
        return StateInputs(
            viewActive: viewActive,
            activePaneInputEligible: paneId.flatMap { paneInputEligibleById[$0] } ?? false,
            activePaneWindowAttached: paneId.flatMap { paneWindowAttachedById[$0] } ?? false,
            allowsLocalInputOwnership: activeTerminalSceneIsForeground
                && inputOwnership.allowsLocalAcquisition,
            userHidKeyboard: isUserHidden,
            findNavigatorActive: findNavigatorState.isActive
        )
    }

    private func markDirty(reason: String) {
        guard syncScheduler.request(reason: reason) else { return }
        scheduleSync()
    }

    private func scheduleSync() {
        DispatchQueue.main.async { [weak self] in
            self?.sync()
        }
    }

    private func syncImmediately(reason: String) {
        _ = syncScheduler.request(reason: reason)
        sync()
    }

    private func sync() {
        guard let reason = syncScheduler.beginSync() else { return }
        defer {
            if syncScheduler.finishSync() {
                scheduleSync()
            }
        }

        let inputs = currentInputs
        let inputSessionDesired = Self.desiredInputSessionActive(inputs: inputs)
        let keyboardPresentationDesired = Self.desiredKeyboardVisible(inputs: inputs)
        if !keyboardPresentationDesired {
            cancelPresentationVerify()
        }

        if let previousPaneId = lastManagedPaneId,
           previousPaneId != activePaneId,
           let previousTerminal = terminalProvider?(previousPaneId) {
            let before = previousTerminal.keyboardCoordinatorDiagnosticSnapshot()
            let transfersDirectlyToActivePane = inputSessionDesired
                && activePaneId.flatMap { terminalProvider?($0) } != nil
            // UIKit can transfer first-responder ownership directly between
            // panes. Resigning first would tear down InputUI and immediately
            // rebuild it for the next pane.
            if before.isFirstResponder, !transfersDirectlyToActivePane {
                previousTerminal.releaseTerminalInput()
                makeLocalInputOwnershipAvailable()
                logCommand(
                    inputSessionDesired: false,
                    keyboardPresentationDesired: false,
                    reason: reason,
                    inputs: inputs,
                    before: before,
                    after: previousTerminal.keyboardCoordinatorDiagnosticSnapshot()
                )
            }
            lastManagedPaneId = nil
        }

        guard let activePaneId,
              let terminal = terminalProvider?(activePaneId) else {
            logNoActiveTerminal(inputSessionDesired: inputSessionDesired, inputs: inputs)
            return
        }
        lastManagedPaneId = activePaneId

        if let recovery = explicitPresentationRecovery,
           recovery.paneId == activePaneId {
            if ObjectIdentifier(terminal) != recovery.terminalIdentifier {
                explicitPresentationRecovery = nil
            } else if recovery.phase == .rebuilding {
                logSteady(
                    inputSessionDesired: inputSessionDesired,
                    keyboardPresentationDesired: keyboardPresentationDesired,
                    inputs: inputs,
                    before: terminal.keyboardCoordinatorDiagnosticSnapshot()
                )
                return
            } else {
                let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
                guard keyboardPresentationDesired,
                      snapshot.windowAttached,
                      snapshot.windowIsKey else {
                    logSteady(
                        inputSessionDesired: inputSessionDesired,
                        keyboardPresentationDesired: keyboardPresentationDesired,
                        inputs: inputs,
                        before: snapshot
                    )
                    return
                }
                explicitPresentationRecovery = nil
                // The responder-free repair turn already completed before
                // entering this phase. Resume with a direct explicit force;
                // never start a second rebuild if focus returned meanwhile.
                pendingPresentationRequest = .forceSoftwareKeyboard(
                    repairActiveSession: false
                )
            }
        }

        let presentationRequest = pendingPresentationRequest
        let before = terminal.keyboardCoordinatorDiagnosticSnapshot()
        recordLocalInputOwnershipIfNeeded(
            snapshot: before
        )
        reconcileSoftwareKeyboardPresentation(
            terminal: terminal,
            snapshot: before
        )
        if inputSessionDesired,
           inputs.userHidKeyboard,
           !before.isKeyboardInBrowseMode {
            _ = terminal.focusTerminalInputWithoutShowingSoftwareKeyboard()
            let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
            recordLocalInputOwnershipIfNeeded(snapshot: after)
            logCommand(
                inputSessionDesired: inputSessionDesired,
                keyboardPresentationDesired: keyboardPresentationDesired,
                reason: reason,
                inputs: inputs,
                before: before,
                after: after
            )
            return
        }
        if keyboardPresentationDesired,
           presentationRequest.waitsForWindowOwnership,
           (!before.windowAttached || !before.windowIsKey) {
            // Keep user and content-protection recovery requests scoped to
            // this pane until its window can own InputUI.
            logSteady(
                inputSessionDesired: inputSessionDesired,
                keyboardPresentationDesired: keyboardPresentationDesired,
                inputs: inputs,
                before: before
            )
            return
        }
        if keyboardPresentationDesired || !presentationRequest.isExplicitSoftwareKeyboardRequest {
            pendingPresentationRequest = .none
        }

        if keyboardPresentationDesired,
           presentationRequest == .contentProtectionRecovery,
           !before.isSoftwareKeyboardSuppressed {
            beginInputSessionReacquisition(
                for: activePaneId,
                terminal: terminal,
                presentationRequest: presentationRequest
            )
            let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
            logAsyncRebuild(inputs: inputs, after: after)
            return
        }

        if keyboardPresentationDesired,
           case .forceSoftwareKeyboard(let repairActiveSession) = presentationRequest {
            let requiresFindRepair = findNavigatorState.requiresTerminalRepair
            if repairActiveSession,
               before.windowAttached,
               before.windowIsKey,
               (requiresFindRepair
                    || before.isSoftwareInputActive) {
                // The explicit request recorded that the active session had
                // no keyboard. A stale layout-guide frame can appear before
                // this queued sync; it must not cancel the one capped repair.
                beginInputSessionReacquisition(
                    for: activePaneId,
                    terminal: terminal,
                    presentationRequest: presentationRequest
                )
                logCommand(
                    inputSessionDesired: inputSessionDesired,
                    keyboardPresentationDesired: keyboardPresentationDesired,
                    reason: reason,
                    inputs: inputs,
                    before: before,
                    after: terminal.keyboardCoordinatorDiagnosticSnapshot()
                )
                return
            }

            let after = acquireTerminalInput(
                terminal,
                for: activePaneId,
                presentationRequest: presentationRequest,
                retryPresentationAfterVerification: presentationRequest == .none
                    ? nil
                    : presentationRequest
            )
            logCommand(
                inputSessionDesired: inputSessionDesired,
                keyboardPresentationDesired: keyboardPresentationDesired,
                reason: reason,
                inputs: inputs,
                before: before,
                after: after
            )
            return
        }

        let refreshRequested = presentationRequest == .automaticRefresh
        // Compare against the software input session, not the combined
        // responder state: the view can hold first responder for native
        // selection, which must not read as "keyboard is up".
        guard before.isSoftwareInputActive != inputSessionDesired else {
            let refreshAction = Self.presentationRefreshAction(
                keyboardPresentationDesired: keyboardPresentationDesired,
                refreshRequested: refreshRequested,
                windowOwnsInput: before.windowAttached && before.windowIsKey,
                softwareInputActive: before.isSoftwareInputActive,
                softwareKeyboardSuppressed: before.isSoftwareKeyboardSuppressed,
                softwareKeyboardVisible: isSoftwareKeyboardVisible,
                presentationVerificationPending: presentationVerifyTask != nil,
                refreshAttemptCount: presentationRefreshAttemptCount,
                refreshAttemptLimit: presentationRefreshAttemptLimit
            )
            switch refreshAction {
            case .deferUntilVerification:
                requestAutomaticPresentationRefresh()
                logDeferredRefresh(inputs: inputs, before: before)
                return
            case .rebuild:
                // The session is active but no keyboard is up. Either the
                // presentation silently failed or a hardware keyboard is
                // suppressing it; rebuild once for the former, then the
                // verifier folds away the native accessory if UIKit still
                // withholds a real keyboard frame.
                beginInputSessionReacquisition(
                    for: activePaneId,
                    terminal: terminal,
                    presentationRequest: .automaticRefresh
                )
                let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
                logAsyncRebuild(inputs: inputs, after: after)
                return
            case .none:
                break
            }
            logSteady(
                inputSessionDesired: inputSessionDesired,
                keyboardPresentationDesired: keyboardPresentationDesired,
                inputs: inputs,
                before: before
            )
            return
        }

        if inputSessionDesired {
            if inputs.userHidKeyboard {
                terminal.focusTerminalInputWithoutShowingSoftwareKeyboard()
            } else {
                _ = acquireTerminalInput(
                    terminal,
                    for: activePaneId,
                    presentationRequest: presentationRequest,
                    retryPresentationAfterVerification: presentationRequest == .none
                        ? nil
                        : presentationRequest
                )
            }
        } else {
            terminal.releaseTerminalInput()
            if inputOwnership.allowsLocalAcquisition {
                makeLocalInputOwnershipAvailable()
            }
        }

        let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
        recordLocalInputOwnershipIfNeeded(
            snapshot: after
        )
        logCommand(
            inputSessionDesired: inputSessionDesired,
            keyboardPresentationDesired: keyboardPresentationDesired,
            reason: reason,
            inputs: inputs,
            before: before,
            after: after
        )

        if keyboardPresentationDesired,
           after.isSoftwareInputActive,
           !isSoftwareKeyboardVisible {
            if presentationVerifyTask == nil {
                schedulePresentationVerify(
                    for: activePaneId,
                    terminal: terminal,
                    retryRequest: presentationRequest == .none ? nil : presentationRequest
                )
            }
        } else {
            cancelPresentationVerify()
            if !inputSessionDesired {
                presentationRefreshAttemptCount = 0
            }
        }
    }

    /// UIKit must observe a responder-free runloop turn before a dead input
    /// scene can be recreated. The terminal owns that UIKit timing detail;
    /// this coordinator retains ownership of *whether* the same terminal may
    /// reacquire input after the asynchronous boundary.
    private func beginInputSessionReacquisition(
        for paneId: UUID,
        terminal: any TerminalKeyboardInputSession,
        presentationRequest: PresentationRequest
    ) {
        let ownershipGeneration = inputOwnership.generation
        guard presentationRefreshAttemptCount < presentationRefreshAttemptLimit else {
            pendingPresentationRequest = .none
            suppressAccessory(for: terminal)
            return
        }
        if findNavigatorState.requiresTerminalRepair {
            findNavigatorState = .inactive
        }
        let explicitRecovery: ExplicitPresentationRecovery?
        if presentationRequest.isExplicitSoftwareKeyboardRequest {
            let recovery = ExplicitPresentationRecovery(
                paneId: paneId,
                terminalIdentifier: ObjectIdentifier(terminal),
                phase: .rebuilding
            )
            explicitPresentationRecovery = recovery
            explicitRecovery = recovery
        } else {
            explicitRecovery = nil
        }
        terminal.releaseTerminalInputForReacquisition { [weak self] in
            guard let self else { return }
            guard self.activeTerminalSceneIsForeground,
                  self.inputOwnership.allowsLocalAcquisition else {
                return
            }
            guard self.inputOwnership.generation == ownershipGeneration else {
                // Losing this window while an explicit repair is in flight
                // invalidates the callback's responder authority, but not the
                // user's request. Resume through normal reconciliation only
                // if the same request still exists and ownership is local.
                if var explicitRecovery,
                   self.explicitPresentationRecovery == explicitRecovery {
                    explicitRecovery.phase = .waitingForActivation
                    self.explicitPresentationRecovery = explicitRecovery
                    self.markDirty(reason: "inputReacquisitionGenerationChanged")
                }
                return
            }
            guard let activeTerminal = self.terminalProvider?(paneId),
                  activeTerminal === terminal else {
                if let explicitRecovery,
                   self.explicitPresentationRecovery == explicitRecovery {
                    self.explicitPresentationRecovery = nil
                }
                self.markDirty(reason: "inputReacquisitionOwnershipChanged")
                return
            }

            if var explicitRecovery {
                guard self.explicitPresentationRecovery == explicitRecovery else {
                    return
                }
                if self.pendingPresentationRequest.isExplicitSoftwareKeyboardRequest {
                    self.explicitPresentationRecovery = nil
                    self.markDirty(reason: "inputReacquisitionSuperseded")
                    return
                }
                if self.pendingPresentationRequest == .automaticRefresh {
                    self.pendingPresentationRequest = .none
                }

                let inputs = self.currentInputs
                let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
                guard self.activePaneId == paneId,
                      Self.desiredKeyboardVisible(inputs: inputs),
                      snapshot.windowAttached,
                      snapshot.windowIsKey else {
                    explicitRecovery.phase = .waitingForActivation
                    self.explicitPresentationRecovery = explicitRecovery
                    return
                }

                self.explicitPresentationRecovery = nil
                _ = self.acquireTerminalInput(
                    terminal,
                    for: paneId,
                    presentationRequest: presentationRequest,
                    retryPresentationAfterVerification: nil
                )
                return
            }

            guard self.activePaneId == paneId else {
                self.markDirty(reason: "inputReacquisitionOwnershipChanged")
                return
            }

            // Any pending request was created after this asynchronous reset
            // began. Let the normal reconciliation consume that newer intent
            // instead of spending its attempt budget with stale policy.
            guard self.pendingPresentationRequest == .none else {
                self.markDirty(reason: "inputReacquisitionSuperseded")
                return
            }

            let inputs = self.currentInputs
            guard Self.desiredKeyboardVisible(inputs: inputs) else {
                self.markDirty(reason: "inputReacquisitionNoLongerDesired")
                return
            }
            let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
            guard snapshot.windowAttached, snapshot.windowIsKey else { return }
            guard !snapshot.isSoftwareInputActive else {
                self.schedulePresentationVerify(for: paneId, terminal: terminal)
                return
            }

            _ = self.acquireTerminalInput(
                terminal,
                for: paneId,
                presentationRequest: presentationRequest,
                retryPresentationAfterVerification: nil
            )
        }
    }

    @discardableResult
    private func acquireTerminalInput(
        _ terminal: any TerminalKeyboardInputSession,
        for paneId: UUID,
        presentationRequest: PresentationRequest,
        retryPresentationAfterVerification: PresentationRequest?
    ) -> TerminalKeyboardCoordinatorDiagnosticSnapshot {
        if presentationRequest == .none {
            // A new ownership session (for example, Find relinquishing its
            // responder) gets a fresh repair budget. Only presentation
            // retries are capped; ordinary input ownership must never be
            // refused because an earlier keyboard scene failed to appear.
            presentationRefreshAttemptCount = 0
        } else {
            guard presentationRefreshAttemptCount < presentationRefreshAttemptLimit else {
                pendingPresentationRequest = .none
                suppressAccessory(for: terminal)
                return terminal.keyboardCoordinatorDiagnosticSnapshot()
            }
            presentationRefreshAttemptCount += 1
        }

        switch presentationRequest {
        case .forceSoftwareKeyboard:
            _ = terminal.forceSoftwareKeyboardInput()
        case .none, .automaticRefresh, .contentProtectionRecovery:
            _ = terminal.acquireTerminalInput()
        }

        let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
        recordLocalInputOwnershipIfNeeded(
            snapshot: after
        )
        reconcileSoftwareKeyboardPresentation(
            terminal: terminal,
            snapshot: after
        )
        finishInputAcquisition(
            paneId: paneId,
            terminal: terminal,
            presentationRequest: presentationRequest,
            retryPresentationAfterVerification: retryPresentationAfterVerification,
            acquired: after.isSoftwareInputActive
        )
        return after
    }

    private func finishInputAcquisition(
        paneId: UUID,
        terminal: any TerminalKeyboardInputSession,
        presentationRequest: PresentationRequest,
        retryPresentationAfterVerification: PresentationRequest?,
        acquired: Bool
    ) {
        guard acquired else {
            cancelPresentationVerify()
            guard Self.desiredKeyboardVisible(inputs: currentInputs) else {
                pendingPresentationRequest = .none
                markDirty(reason: "inputAcquisitionNoLongerDesired")
                return
            }

            let retryRequest = presentationRequest == .none
                ? PresentationRequest.automaticRefresh
                : presentationRequest
            if presentationRefreshAttemptCount < presentationRefreshAttemptLimit {
                if pendingPresentationRequest == .none || pendingPresentationRequest == retryRequest {
                    pendingPresentationRequest = retryRequest
                }
                markDirty(reason: "inputAcquisitionFailed")
            } else {
                if pendingPresentationRequest == retryRequest {
                    pendingPresentationRequest = .none
                }
                suppressAccessory(for: terminal)
            }
            return
        }

        if terminal.keyboardCoordinatorDiagnosticSnapshot().isSoftwareKeyboardSuppressed {
            cancelPresentationVerify()
            return
        }

        if isSoftwareKeyboardVisible {
            terminal.setTerminalInputAccessorySuppressed(false)
        } else {
            schedulePresentationVerify(
                for: paneId,
                terminal: terminal,
                retryRequest: retryPresentationAfterVerification
            )
        }
    }

    /// UIKit can accept the input session while legitimately withholding the
    /// software keyboard (hardware keyboard, iPhone Mirroring), or while a
    /// hosted keyboard scene is temporarily broken. Settle both cases by
    /// folding the accessory if no real keyboard frame arrives. A refresh
    /// requested while presentation is still in flight waits for this check;
    /// only a settled failure gets one rebuild. That preserves the "tap once
    /// after mirroring" repair path without restarting a keyboard animation.
    private func schedulePresentationVerify(
        for paneId: UUID,
        terminal: any TerminalKeyboardInputSession,
        retryRequest: PresentationRequest? = nil,
        layoutSource: PresentationVerificationLayoutSource = .currentLayoutFrame
    ) {
        let ownershipGeneration = inputOwnership.generation
        presentationVerifyTask?.cancel()
        presentationVerifyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.presentationVerifyTask = nil
            guard self.inputOwnership.generation == ownershipGeneration,
                  self.activeTerminalSceneIsForeground,
                  self.inputOwnership.allowsLocalAcquisition,
                  self.activePaneId == paneId,
                  let activeTerminal = self.terminalProvider?(paneId),
                  activeTerminal === terminal else { return }
            let snapshot = terminal.keyboardCoordinatorDiagnosticSnapshot()
            if layoutSource.reconcilesLayoutFrameAtDeadline {
                self.reconcileSoftwareKeyboardPresentation(
                    terminal: terminal,
                    snapshot: snapshot
                )
            }
            guard !self.isSoftwareKeyboardVisible else { return }
            let inputs = self.currentInputs
            guard Self.desiredKeyboardVisible(inputs: inputs) else { return }
            guard snapshot.windowAttached,
                  snapshot.windowIsKey,
                  snapshot.isSoftwareInputActive,
                  !snapshot.isSoftwareKeyboardSuppressed else { return }
            if self.pendingPresentationRequest != .none {
                self.markDirty(reason: "presentationUnverified")
                return
            }
            if let retryRequest,
               self.presentationRefreshAttemptCount < self.presentationRefreshAttemptLimit {
                self.pendingPresentationRequest = retryRequest
                self.markDirty(reason: "presentationUnverified")
                return
            }
            // Settled with an active session and no keyboard: hardware mode
            // or a failed software-keyboard presentation. Keep the responder
            // for hardware keys, but remove the accessory until a real
            // software keyboard frame arrives or the user tries focus again.
            self.suppressAccessory(for: terminal)
            let after = terminal.keyboardCoordinatorDiagnosticSnapshot()
            self.logVerifySuppressed(after: after)
        }
    }

    private func cancelPresentationVerify() {
        presentationVerifyTask?.cancel()
        presentationVerifyTask = nil
    }

    private func logKeyboardNotification(
        name: String,
        object: String,
        beginFrame: CGRect?,
        endFrame: CGRect?,
        isLocal: Bool?,
        duration: TimeInterval?,
        curveRawValue: Int?
    ) {
        guard lifecycleLoggingEnabled else { return }
        let beginDescription = beginFrame?.debugDescription ?? "nil"
        let endDescription = endFrame?.debugDescription ?? "nil"
        let localDescription = isLocal.map { String($0) } ?? "nil"
        let durationDescription = duration.map { String($0) } ?? "nil"
        let curveDescription = curveRawValue.map { String($0) } ?? "nil"
        let terminalDescription = activeTerminal?
            .keyboardCoordinatorDiagnosticSnapshot()
            .lifecycleDescription ?? "noActiveTerminal=true"
        logger.info(
            "event=keyboardNotification name=\(name, privacy: .public) object=\(object, privacy: .public) begin=\(beginDescription, privacy: .public) end=\(endDescription, privacy: .public) local=\(localDescription, privacy: .public) duration=\(durationDescription, privacy: .public) curve=\(curveDescription, privacy: .public) \(terminalDescription, privacy: .public)"
        )
    }

    private func logExplicitPresentationRequest() {
        guard lifecycleLoggingEnabled else { return }
        let terminalDescription = activeTerminal?
            .keyboardCoordinatorDiagnosticSnapshot()
            .lifecycleDescription ?? "noActiveTerminal=true"
        logger.info(
            "event=userRequestedShow userHidden=\(self.isUserHidden) keyboardVisible=\(self.isSoftwareKeyboardVisible) \(terminalDescription, privacy: .public)"
        )
    }

    private func logNoActiveTerminal(inputSessionDesired: Bool, inputs: StateInputs) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=none reason=\(self.syncScheduler.reason, privacy: .public) inputDesired=\(inputSessionDesired) noActiveTerminal=true viewActive=\(inputs.viewActive) inputEligible=\(inputs.activePaneInputEligible) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive)")
    }

    private func logAsyncRebuild(
        inputs: StateInputs,
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=refresh repair=asyncRebuild reason=\(self.syncScheduler.reason, privacy: .public) viewActive=\(inputs.viewActive) inputEligible=\(inputs.activePaneInputEligible) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) \(after.lifecycleDescription, privacy: .public)")
    }

    private func logDeferredRefresh(
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=refresh repair=deferred reason=\(self.syncScheduler.reason, privacy: .public) viewActive=\(inputs.viewActive) inputEligible=\(inputs.activePaneInputEligible) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) \(before.lifecycleDescription, privacy: .public)")
    }

    private func logSteady(
        inputSessionDesired: Bool,
        keyboardPresentationDesired: Bool,
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=steady reason=\(self.syncScheduler.reason, privacy: .public) inputDesired=\(inputSessionDesired) keyboardDesired=\(keyboardPresentationDesired) viewActive=\(inputs.viewActive) inputEligible=\(inputs.activePaneInputEligible) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) \(before.lifecycleDescription, privacy: .public)")
    }

    private func logVerifySuppressed(
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info("command=verifySuppressed kbVisible=\(self.isSoftwareKeyboardVisible) \(after.lifecycleDescription, privacy: .public)")
    }

    private func logCommand(
        inputSessionDesired: Bool,
        keyboardPresentationDesired: Bool,
        reason: String,
        inputs: StateInputs,
        before: TerminalKeyboardCoordinatorDiagnosticSnapshot,
        after: TerminalKeyboardCoordinatorDiagnosticSnapshot
    ) {
        guard lifecycleLoggingEnabled else { return }
        logger.info(
            "command=\(inputSessionDesired ? "acquire" : "release", privacy: .public) inputDesired=\(inputSessionDesired) keyboardDesired=\(keyboardPresentationDesired) reason=\(reason, privacy: .public) viewActive=\(inputs.viewActive) inputEligible=\(inputs.activePaneInputEligible) windowAttached=\(inputs.activePaneWindowAttached) userHidden=\(inputs.userHidKeyboard) find=\(inputs.findNavigatorActive) kbVisible=\(self.isSoftwareKeyboardVisible) before={\(before.lifecycleDescription, privacy: .public)} after={\(after.lifecycleDescription, privacy: .public)}"
        )
    }

    #if DEBUG
    var keyboardUITestPresentationVerificationPending: Bool {
        presentationVerifyTask != nil
    }

    func keyboardUITestReceiveKeyboardEndFrame(
        _ frame: CGRect?,
        isLocal: Bool
    ) {
        noteKeyboardEndFrame(
            frame,
            isLocal: isLocal,
            sourceScreenIdentifier: nil,
            animationDuration: nil,
            animationCurve: nil
        )
    }

    func keyboardUITestSetSoftwareKeyboardEndFrame(
        _ frame: CGRect?,
        isLocal: Bool = true
    ) {
        guard isLocal else {
            noteExternalKeyboardOwnership()
            return
        }
        guard Self.desiredKeyboardVisible(inputs: currentInputs) else {
            setSoftwareKeyboardPresentation(.hidden)
            return
        }
        let snapshot = activeTerminal?.keyboardCoordinatorDiagnosticSnapshot()
        let presentation: SoftwareKeyboardPresentation
        if let frame {
            presentation = Self.softwareKeyboardPresentation(
                for: frame,
                in: snapshot?.screenFrame ?? frame,
                minimumHeight: 0
            )
        } else {
            presentation = .hidden
        }
        setSoftwareKeyboardPresentation(presentation)
    }

    func keyboardUITestReceiveSoftwareKeyboardHidden() {
        handleLocalSoftwareKeyboardHidden(
            sourceScreenIdentifier: nil,
            animationDuration: nil,
            animationCurve: nil
        )
    }
    #endif
}
#endif
