//
//  GhosttyTerminalKeyboardTestSupport+iOS.swift
//  VVTerm
//
//  iOS keyboard UI test support.
//

#if os(iOS)
import UIKit

#if DEBUG
extension GhosttyTerminalView {
    var keyboardUITestInputViewReloadCount: Int {
        keyboardInputViewReloadCount
    }

    var keyboardUITestInputSessionRebuildCount: Int {
        keyboardInputSessionRebuildCount
    }

    func keyboardUITestDiagnostics(keyboardVisible: Bool, keyboardHeight: CGFloat) -> String {
        let snapshot = keyboardCoordinatorDiagnosticSnapshot()
        let accessoryAttached = keyboardToolbar?.window != nil
        let accessoryAppearance = keyboardToolbar?.diagnosticBackgroundAppearance ?? "missing"
        let accessoryOwnerStyle = keyboardToolbar?.diagnosticOwnerInterfaceStyle ?? "missing"
        let accessoryHostStyle = keyboardToolbar?.diagnosticHostInterfaceStyle ?? "missing"
        let accessoryResolvedStyle = keyboardToolbar?.diagnosticResolvedInterfaceStyle ?? "missing"
        let accessoryHeight = keyboardToolbar?.diagnosticHeight ?? 0
        let accessoryFittingHeight = keyboardToolbar?.diagnosticFittingHeight ?? 0
        let accessorySelfSizing = keyboardToolbar?.allowsSelfSizing == true
        let keyboardHeightText = String(format: "%.1f", Double(keyboardHeight))
        let accessoryHeightText = String(format: "%.1f", Double(accessoryHeight))
        let accessoryFittingHeightText = String(
            format: "%.1f",
            Double(accessoryFittingHeight)
        )
        let size = terminalSize()
        let inputViewMode = keyboardUITestSoftwareKeyboardFailure == .untilSessionRebuild
            ? "testUnexpectedHidden"
            : (shouldSuppressSoftwareKeyboard ? "policyHidden" : "system")
        return [
            "windowAttached=\(snapshot.windowAttached)",
            "keyWindow=\(snapshot.windowIsKey)",
            "scene=\(snapshot.sceneActivationState)",
            "terminalId=\(ObjectIdentifier(self))",
            "inputResponderId=\(ObjectIdentifier(imeProxyTextView))",
            "windowId=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil")",
            "terminalFirstResponder=\(snapshot.isFirstResponder)",
            "softwareInputActive=\(snapshot.isSoftwareInputActive)",
            "imeProxyFirstResponder=\(imeProxyTextView.isFirstResponder)",
            "viewFirstResponder=\(super.isFirstResponder)",
            "keyboardVisible=\(keyboardVisible)",
            "keyboardHeight=\(keyboardHeightText)",
            "gridCols=\(size.map { String($0.columns) } ?? "0")",
            "gridRows=\(size.map { String($0.rows) } ?? "0")",
            "gridResizes=\(keyboardUITestGridResizeCount)",
            "renderingPaused=\(isRenderingPaused)",
            "surfaceFocused=\(keyboardUITestSurfaceFocused)",
            "sizePreserved=\(keyboardAvoidancePreservedSurfaceSize != nil)",
            "accessoryAttached=\(accessoryAttached)",
            "accessoryAppearance=\(accessoryAppearance)",
            "accessoryOwnerStyle=\(accessoryOwnerStyle)",
            "accessoryHostStyle=\(accessoryHostStyle)",
            "accessoryResolvedStyle=\(accessoryResolvedStyle)",
            "accessoryHeight=\(accessoryHeightText)",
            "accessoryFittingHeight=\(accessoryFittingHeightText)",
            "accessorySelfSizing=\(accessorySelfSizing)",
            "accessorySuppressed=\(suppressAccessoryForMissingSoftwareKeyboard)",
            "accessoryHidden=\(shouldHideKeyboardAccessoryBar)",
            "hardware=\(hasHardwareKeyboardAttached)",
            "keyboardForced=\(keyboardFocusPolicy.forcesSoftwareKeyboardPresentation)",
            "softwareKeyboardSuppressed=\(shouldSuppressSoftwareKeyboard)",
            "inputViewMode=\(inputViewMode)",
            "browse=\(keyboardFocusPolicy.isBrowsing)",
            "find=\(isFindNavigatorActive)",
            "nativeSelectionActive=\(hasActiveSelectionInteraction)",
            "nativeSelectionLength=\(nativeSelectedRange?.length ?? 0)",
            "eligible=\(isTextInputSessionEligible)",
            "imeProxyCanBecome=\(imeProxyTextView.canBecomeFirstResponder)",
            "imeComposing=\(textInputModel.hasActiveIMEComposition)",
            "imeMarkedText=\(keyboardUITestToken(textInputModel.markedText))",
            "imeModelText=\(keyboardUITestToken(textInputModel.text))",
            "hardwareRepeatPhase=\(keyboardUITestHardwareRepeatPhase)",
            "hardwarePresses=\(hardwarePressesSentToGhostty.count)",
            "hideRequests=\(keyboardHideRequestCount)",
            "inputRebuilds=\(keyboardInputSessionRebuildCount)",
            "inputReloads=\(keyboardInputViewReloadCount)"
        ].joined(separator: " ")
    }

    func keyboardUITestMoveCursorToBottom() {
        let lines = (0..<200).map { "line-\($0)" }.joined(separator: "\r\n") + "\r\n"
        feedData(Data(lines.utf8))
    }

    func keyboardUITestSetMarkedText(_ text: String) {
        guard !text.isEmpty else { return }
        if !imeProxyTextView.isFirstResponder {
            _ = requestKeyboardFocus(for: .initialActivation)
        }
        let selectedLocation = (text as NSString).length
        imeProxyTextView.setMarkedText(
            text,
            selectedRange: NSRange(location: selectedLocation, length: 0)
        )
    }

    func keyboardUITestBeginLayoutResolvedHardwareKeyRepeat(text: String, shifted: Bool) {
        guard !text.isEmpty, let surface else { return }
        keyboardUITestUsesManualHardwareKeyRepeatClock = true
        cancelTrackedHardwareInput()

        let keyCode = UInt16(UIKeyboardHIDUsage.keyboardH.rawValue)
        let modifiers: UIKeyModifierFlags = shifted ? [.shift] : []
        let ghosttyModifiers = Ghostty.Input.Mods(uiKeyModifiers: modifiers)
        if shifted {
            let shiftKeyCode = UInt16(UIKeyboardHIDUsage.keyboardLeftShift.rawValue)
            let shiftEvent = Ghostty.Input.KeyEvent(
                key: .shiftLeft,
                action: .press,
                mods: ghosttyModifiers,
                consumedMods: ghosttyModifiers
            )
            surface.sendKeyEvent(shiftEvent)
            hardwarePressesSentToGhostty[shiftKeyCode] = shiftEvent
            systemTextInputPresses.insert(shiftKeyCode)
        }
        let sourceEvent = Ghostty.Input.KeyEvent(
            key: .h,
            action: .press,
            text: text,
            composing: false,
            mods: ghosttyModifiers,
            consumedMods: ghosttyModifiers,
            unshiftedCodepoint: 0x68
        )
        _ = sendResolvedInterpretedHardwareKeyText(
            text,
            keyCode: keyCode,
            modifiers: modifiers,
            sourceEvent: sourceEvent,
            repeatSource: .layoutResolvedText
        )
    }

    func keyboardUITestFireHardwareKeyRepeat() {
        guard let token = activeHardwareKeyRepeat?.token else { return }
        handleHardwareKeyRepeatTick(token: token)
    }

    func keyboardUITestEndHardwareKeyRepeat() {
        guard let active = activeHardwareKeyRepeat,
              let ended = endHardwareKeyRepeat(keyCode: active.keyCode) else { return }
        systemTextInputPresses.remove(ended.keyCode)
        let pressedEvent = hardwarePressesSentToGhostty.removeValue(forKey: ended.keyCode)
        surface?.sendKeyEvent(hardwareKeyEvent(pressedEvent ?? ended.payload, action: .release))
        requestRender()
    }

    func keyboardUITestCancelHardwareKeyRepeat() {
        cancelTrackedHardwareInput()
    }

    func keyboardUITestDeleteBackwardThroughIMEProxy() {
        if !imeProxyTextView.isFirstResponder {
            _ = requestKeyboardFocus(for: .initialActivation)
        }
        imeProxyTextView.deleteBackward()
    }

    func keyboardUITestCommitMarkedText() {
        imeProxyTextView.unmarkText()
    }

    func keyboardUITestSendSoftwareShortcut(
        _ text: String,
        modifiers: TerminalAccessoryShortcutModifiers
    ) {
        _ = resolvedInputAccessoryView()
        keyboardToolbar?.keyboardUITestSetModifiers(modifiers)
        _ = handleIMEProxyInsertText(text)
    }

    func keyboardUITestSendToolbarShortcut(
        _ key: TerminalKey,
        modifiers: TerminalAccessoryShortcutModifiers
    ) {
        sendToolbarKey(.modified(key, mods: modifiers.ghosttyModifiers))
    }

    func keyboardUITestSendCustomShortcut(
        _ key: TerminalAccessoryShortcutKey,
        modifiers: TerminalAccessoryShortcutModifiers
    ) {
        handleToolbarCustomAction(
            TerminalAccessoryCustomAction(
                title: "Keyboard shortcut routing test",
                kind: .shortcut,
                shortcutKey: key,
                shortcutModifiers: modifiers
            )
        )
    }

    @discardableResult
    func keyboardUITestSendRegisteredKeyCommand(
        _ input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        guard let command = keyCommands?.first(where: {
            $0.input == input && $0.modifierFlags == modifiers
        }), let action = command.action,
              imeProxyTextView.isFirstResponder,
              let target = imeProxyTextView.target(
                  forAction: action,
                  withSender: command
              ) as AnyObject?,
              target === self else {
            return false
        }
        return UIApplication.shared.sendAction(
            action,
            to: target,
            from: command,
            for: nil
        )
    }

    func keyboardUITestRequestHardwareKeyboardFocus() {
        _ = requestKeyboardFocus(for: .hardwareKeyboard)
    }

    func keyboardUITestSetHardwareKeyboardAttached(_ attached: Bool) {
        keyboardUITestHardwareKeyboardOverride = attached
        let previousInputConfiguration = terminalInputConfiguration
        if setHardwareKeyboardAttached(attached) {
            notifyKeyboardBrowseModeChange(
                previousInputConfiguration: previousInputConfiguration
            )
        }
        if attached {
            focusForHardwareKeyboardIfNeeded()
        } else if isTerminalTextInputActive, isTextInputSessionEligible, !isFindNavigatorActive {
            _ = requestKeyboardFocus(for: .initialActivation)
        }
        if previousInputConfiguration == terminalInputConfiguration {
            reloadTerminalInputViewsIfActive()
        }
    }

    func keyboardUITestBeginUnexpectedSoftwareKeyboardLoss() {
        keyboardUITestSoftwareKeyboardFailure = .untilSessionRebuild
        reloadTerminalInputViewsIfActive()
    }

    private var keyboardUITestHardwareRepeatPhase: String {
        switch hardwareKeyRepeatState.phase {
        case .idle:
            "idle"
        case .repeating:
            "repeating"
        }
    }

    private func keyboardUITestToken(_ value: String) -> String {
        guard !value.isEmpty else { return "empty" }
        return value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
#endif

#endif
