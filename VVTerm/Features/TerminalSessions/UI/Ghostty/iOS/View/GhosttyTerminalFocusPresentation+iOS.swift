//
//  GhosttyTerminalFocusPresentation+iOS.swift
//  VVTerm
//
//  iOS terminal focus and keyboard presentation.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    enum TerminalInputConfiguration: Equatable {
        case systemWithAccessory
        case systemWithoutAccessory
        case suppressed
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    var isTextInputSessionEligible: Bool {
        guard !isShuttingDown else { return false }
        guard window != nil, !isHidden, alpha > 0.01 else { return false }
        if let activationState = window?.windowScene?.activationState {
            return activationState == .foregroundActive
        }
        return UIApplication.shared.applicationState == .active
    }

    var isFindNavigatorVisible: Bool {
        isFindNavigatorActive
    }

    var isHardwareKeyboardAttached: Bool {
        hasHardwareKeyboardAttached
    }

    var shouldRestoreKeyboardFocusOnReconnect: Bool {
        keyboardFocusPolicy.shouldRestoreOnReconnect
    }

    var allowsAutomaticKeyboardFocus: Bool {
        keyboardFocusPolicy.allowsAutomaticFocus && !isFindNavigatorActive
    }

    var isKeyboardInBrowseMode: Bool {
        keyboardFocusPolicy.isBrowsing
    }

    var isFindNavigatorActive: Bool {
        guard #available(iOS 16.0, *) else { return false }
        return findNavigatorLifecycle.isActive
            || nativeFindInteraction?.isFindNavigatorVisible == true
    }

    var canRouteTerminalInput: Bool {
        acceptsTerminalInput && !isFindNavigatorActive
    }

    var canRouteProxyDeleteBackward: Bool {
        canRouteTerminalInput
    }

    var isTerminalTextInputActive: Bool {
        isKeyboardTextInputActive || super.isFirstResponder
    }

    var isKeyboardTextInputActive: Bool {
        imeProxyTextView.isFirstResponder
    }

    var shouldSuppressSoftwareKeyboard: Bool {
        keyboardFocusPolicy.shouldSuppressSoftwareKeyboard(
            hasHardwareKeyboardAttached: hasHardwareKeyboardAttached
        )
    }

    var terminalInputConfiguration: TerminalInputConfiguration {
        if shouldSuppressSoftwareKeyboard {
            return .suppressed
        }
        if isFindNavigatorActive || suppressAccessoryForMissingSoftwareKeyboard {
            return .systemWithoutAccessory
        }
        return .systemWithAccessory
    }

    func resolvedInputView() -> UIView? {
        #if DEBUG
        if keyboardUITestSoftwareKeyboardFailure == .untilSessionRebuild {
            return hiddenKeyboardInputView
        }
        #endif
        return shouldSuppressSoftwareKeyboard ? hiddenKeyboardInputView : nil
    }

    func reloadTerminalInputViewsIfActive() {
        guard imeProxyTextView.isFirstResponder else { return }
        #if DEBUG
        keyboardInputViewReloadCount += 1
        #endif
        imeProxyTextView.reloadInputViews()
    }

    func reloadTerminalInputViews(
        ifChangedFrom previousInputConfiguration: TerminalInputConfiguration
    ) {
        guard previousInputConfiguration != terminalInputConfiguration else { return }
        reloadTerminalInputViewsIfActive()
    }

    @discardableResult
    func acquireTerminalInput() -> Bool {
        requestKeyboardFocus(for: .initialActivation)
    }

    @discardableResult
    func forceSoftwareKeyboardInput() -> Bool {
        requestKeyboardFocus(for: .explicitUserRequest)
    }

    @discardableResult
    func requestKeyboardFocus(for reason: TerminalKeyboardFocusReason) -> Bool {
        let reasonDescription = String(describing: reason)
        logKeyboardLifecycle("focus.request.begin", detail: "reason=\(reasonDescription)")
        guard prepareKeyboardFocus(for: reason) else {
            logKeyboardLifecycle("focus.request.rejected", result: false, detail: "reason=\(reasonDescription)")
            return false
        }
        let result = becomeFirstResponder()
        logKeyboardLifecycle("focus.request.end", result: result, detail: "reason=\(reasonDescription)")
        return result
    }

    private func prepareKeyboardFocus(for reason: TerminalKeyboardFocusReason) -> Bool {
        guard !isFindNavigatorActive else { return false }
        if reason != .hardwareKeyboard {
            refreshHardwareKeyboardAttachmentFromSystem()
        }
        let previousInputConfiguration = terminalInputConfiguration
        guard keyboardFocusPolicy.requestFocus(for: reason) else { return false }
        clearNativeSelectionStateForTerminalInput()
        notifyKeyboardBrowseModeChange(
            previousInputConfiguration: previousInputConfiguration
        )
        return true
    }

    func dismissKeyboardForUser(suppressDirectTouchRefocus: Bool = false) {
        let previousInputConfiguration = terminalInputConfiguration
        keyboardFocusPolicy.dismissForUser()
        notifyKeyboardBrowseModeChange(
            previousInputConfiguration: previousInputConfiguration
        )
        if suppressDirectTouchRefocus {
            suppressDirectTouchKeyboardFocusUntil = Date().addingTimeInterval(0.35)
        }
        if !isTerminalTextInputActive {
            _ = focusTerminalInputWithoutShowingSoftwareKeyboard()
        }
    }

    @discardableResult
    func focusTerminalInputWithoutShowingSoftwareKeyboard() -> Bool {
        guard !isFindNavigatorActive else { return false }
        let previousInputConfiguration = terminalInputConfiguration
        keyboardFocusPolicy.dismissForUser()
        refreshHardwareKeyboardAttachmentFromSystem()
        clearNativeSelectionStateForTerminalInput()
        notifyKeyboardBrowseModeChange(
            previousInputConfiguration: previousInputConfiguration
        )
        return becomeFirstResponder()
    }

    func focusForHardwareKeyboardIfNeeded() {
        guard hasHardwareKeyboardAttached,
              canRouteTerminalInput,
              isTextInputSessionEligible,
              !isFindNavigatorActive else {
            return
        }
        guard keyboardFocusPolicy.isBrowsing || !isTerminalTextInputActive else {
            return
        }
        _ = requestKeyboardFocus(for: .hardwareKeyboard)
    }

    @discardableResult
    func exitNativeSelectionTextInputContextForTerminalInput() -> Bool {
        guard isNativeSelectionTextInputContext else { return true }
        guard !isFindNavigatorActive else { return false }

        clearNativeSelectionStateForTerminalInput()
        notifyDirectTouchOnTerminal()
        return true
    }

    func clearNativeSelectionStateForTerminalInput() {
        guard usesNativeTouchSelection else { return }
        let hadSelection = nativeSelectionLifecycle.selection != nil
        if hadSelection {
            imeProxyTextView.inputDelegate?.selectionWillChange(imeProxyTextView)
        }
        nativeSelectionLifecycle.cancel()
        if hadSelection {
            imeProxyTextView.inputDelegate?.selectionDidChange(imeProxyTextView)
        }
    }

    func releaseTerminalInput() {
        _ = resignFirstResponder()
    }

    func dismissKeyboardFromToolbar() {
        #if DEBUG
        keyboardHideRequestCount += 1
        #endif
        // Publish the user's intent while the accessory is still mounted. The
        // route can then install its Keyboard/Voice recovery controls before
        // UIKit tears down the input view hierarchy.
        onKeyboardAccessoryHideRequested?()
        dismissKeyboardForUser(suppressDirectTouchRefocus: true)
    }

    func shouldAutoFocusKeyboard(for touches: Set<UITouch>) -> Bool {
        guard !isFindNavigatorActive else { return false }
        guard keyboardFocusPolicy.allowsAutomaticFocus else { return false }
        guard touches.contains(where: { $0.type == .direct }) else { return true }
        return Date() >= suppressDirectTouchKeyboardFocusUntil
    }

    func setTerminalInputAccessorySuppressed(_ suppressed: Bool) {
        guard suppressAccessoryForMissingSoftwareKeyboard != suppressed else { return }
        let previousInputConfiguration = terminalInputConfiguration
        suppressAccessoryForMissingSoftwareKeyboard = suppressed
        if previousInputConfiguration != terminalInputConfiguration {
            reloadTerminalInputViewsIfActive()
        }
        logKeyboardLifecycle("accessory.suppression.changed", detail: "suppressed=\(suppressed)")
    }

    func notifyKeyboardBrowseModeChange(
        previousInputConfiguration: TerminalInputConfiguration
    ) {
        onKeyboardBrowseModeChange?(keyboardFocusPolicy.isBrowsing)
        if previousInputConfiguration != terminalInputConfiguration {
            reloadTerminalInputViewsIfActive()
        }
    }

    /// Tears the input session down and rebuilds it across runloop turns.
    /// A same-tick resign/become pair is coalesced by UIKit into "nothing
    /// changed" and cannot revive a dead keyboard scene (iOS 26 "No scene
    /// exists for this identity"); the responder-free turn gives InputUI a
    /// real session boundary before the coordinator requests reacquisition.
    func releaseTerminalInputForReacquisition(completion: @escaping () -> Void) {
        #if DEBUG
        keyboardInputSessionRebuildCount += 1
        #endif
        logKeyboardLifecycle("session.rebuild.begin")
        releaseTerminalInput()
        #if DEBUG
        if keyboardUITestSoftwareKeyboardFailure == .untilSessionRebuild {
            keyboardUITestSoftwareKeyboardFailure = .none
        }
        #endif
        logKeyboardLifecycle("session.rebuild.released")
        DispatchQueue.main.async { [weak self] in
            self?.logKeyboardLifecycle("session.rebuild.readyForReacquisition")
            completion()
        }
    }

    func notifyFindNavigatorVisibilityChange(_ visibilityOverride: Bool? = nil) {
        onFindNavigatorVisibilityChange?(visibilityOverride ?? isFindNavigatorVisible)
    }

    func notifyDirectTouchOnTerminal(isFocusTap: Bool = false) {
        guard !isFindNavigatorActive else { return }
        terminalContextMenuActions?.focus()
        onTerminalDirectTouch?(isFocusTap)
    }

    override var isFirstResponder: Bool {
        isTerminalTextInputActive
    }

    override func becomeFirstResponder() -> Bool {
        guard isTextInputSessionEligible else { return false }
        return imeProxyTextView.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        guard imeProxyTextView.isFirstResponder || super.isFirstResponder else { return true }
        let proxyResult: Bool
        if imeProxyTextView.isFirstResponder {
            proxyResult = imeProxyTextView.resignFirstResponder()
        } else {
            proxyResult = true
        }
        let ownResult = super.isFirstResponder ? super.resignFirstResponder() : true
        if (proxyResult && ownResult) || !isTextInputSessionEligible {
            imeProxyFocusDidChange(isFocused: false)
            pendingSystemTextInputHardwareKeys.removeAll()
        }
        return (proxyResult && ownResult) || !isTextInputSessionEligible
    }
}

#endif
