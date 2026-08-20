//
//  GhosttyTerminalHardwarePressRouting+iOS.swift
//  VVTerm
//
//  iOS hardware press routing into terminal and system text input.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    private func shouldRedirectNativeSelectionPressesToTerminalInput(_ presses: Set<UIPress>) -> Bool {
        guard isNativeSelectionTextInputContext else { return false }
        return presses.contains { press in
            guard let key = press.key else { return false }
            return !key.modifierFlags.contains(.command)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if shouldRedirectNativeSelectionPressesToTerminalInput(presses) {
            guard exitNativeSelectionTextInputContextForTerminalInput() else {
                super.pressesBegan(presses, with: event)
                return
            }
            imeProxyTextView.pressesBegan(presses, with: event)
            return
        }

        let pendingCount = pendingSystemTextInputHardwareKeys.count
        let result = processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
            removeUnconsumedPendingSystemTextInputHardwareKeys(after: pendingCount)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let result = processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        processHardwarePressesCancelled(presses)
    }

    private func isRepeatableSpecialHardwareKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardDeleteOrBackspace,
             .keyboardDeleteForward,
             .keyboardUpArrow,
             .keyboardDownArrow,
             .keyboardLeftArrow,
             .keyboardRightArrow,
             .keyboardHome,
             .keyboardEnd,
             .keyboardPageUp,
             .keyboardPageDown:
            return true
        default:
            return false
        }
    }

    private func isPrintableHardwareKeyEvent(_ event: Ghostty.Input.KeyEvent) -> Bool {
        event.unshiftedCodepoint >= 0x20 || !(event.text?.isEmpty ?? true)
    }

    private func fallbackHardwareKey(for key: UIKey) -> Ghostty.Input.Key? {
        switch key.keyCode {
        case .keyboardLeftShift:
            return .shiftLeft
        case .keyboardRightShift:
            return .shiftRight
        case .keyboardCapsLock:
            return .capsLock
        case .keyboardReturnOrEnter:
            return .enter
        case .keyboardDeleteOrBackspace:
            return .backspace
        case .keyboardDeleteForward:
            return .delete
        case .keyboardTab:
            return .tab
        case .keyboardEscape:
            return .escape
        case .keyboardUpArrow:
            return .arrowUp
        case .keyboardDownArrow:
            return .arrowDown
        case .keyboardLeftArrow:
            return .arrowLeft
        case .keyboardRightArrow:
            return .arrowRight
        case .keyboardHome:
            return .home
        case .keyboardEnd:
            return .end
        case .keyboardPageUp:
            return .pageUp
        case .keyboardPageDown:
            return .pageDown
        default:
            break
        }

        let candidates = [key.charactersIgnoringModifiers, key.characters]
        for candidate in candidates where !candidate.isEmpty {
            switch candidate {
            case "UIKeyInputEscape":
                return .escape
            case "UIKeyInputUpArrow":
                return .arrowUp
            case "UIKeyInputDownArrow":
                return .arrowDown
            case "UIKeyInputLeftArrow":
                return .arrowLeft
            case "UIKeyInputRightArrow":
                return .arrowRight
            case "UIKeyInputHome":
                return .home
            case "UIKeyInputEnd":
                return .end
            case "UIKeyInputPageUp":
                return .pageUp
            case "UIKeyInputPageDown":
                return .pageDown
            case UIKeyCommand.inputEscape:
                return .escape
            case UIKeyCommand.inputUpArrow:
                return .arrowUp
            case UIKeyCommand.inputDownArrow:
                return .arrowDown
            case UIKeyCommand.inputLeftArrow:
                return .arrowLeft
            case UIKeyCommand.inputRightArrow:
                return .arrowRight
            case UIKeyCommand.inputHome:
                return .home
            case UIKeyCommand.inputEnd:
                return .end
            case UIKeyCommand.inputPageUp:
                return .pageUp
            case UIKeyCommand.inputPageDown:
                return .pageDown
            default:
                continue
            }
        }

        return nil
    }

    @discardableResult
    func registerHardwareKeyRepeat(
        keyCode: UInt16,
        source: TerminalHardwareKeyRepeatSource,
        event: Ghostty.Input.KeyEvent,
        isRepeatableSpecialKey: Bool,
        modifiers: UIKeyModifierFlags,
        hasActiveIMEComposition: Bool
    ) -> TerminalHardwareKeyRepeatState<Ghostty.Input.KeyEvent>.Registration? {
        guard TerminalHardwareKeyRepeatPolicy.shouldRepeat(
            source: source,
            isPrintableKey: isPrintableHardwareKeyEvent(event),
            isRepeatableSpecialKey: isRepeatableSpecialKey,
            hasControlModifier: modifiers.contains(.control),
            hasAlternateModifier: modifiers.contains(.alternate),
            hasCommandModifier: modifiers.contains(.command),
            hasActiveIMEComposition: hasActiveIMEComposition
        ) else {
            return nil
        }

        let registration = hardwareKeyRepeatState.register(
            keyCode: keyCode,
            payload: event
        )
        if case .started(let active) = registration {
            logKeyboardLifecycle(
                "hardware.repeat.started",
                detail: "keyCode=\(keyCode) source=\(source.lifecycleDescription)"
            )
            scheduleHardwareKeyRepeatTimer(token: active.token)
        }
        return registration
    }

    private func scheduleHardwareKeyRepeatTimer(token: UUID) {
        stopHardwareKeyRepeatTimer()
        #if DEBUG
        guard !keyboardUITestUsesManualHardwareKeyRepeatClock else { return }
        #endif
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            self?.handleHardwareKeyRepeatTick(token: token)
        }
        keyRepeatTimer = timer
        timer.resume()
    }

    private func stopHardwareKeyRepeatTimer() {
        keyRepeatTimer?.cancel()
        keyRepeatTimer = nil
    }

    var activeHardwareKeyRepeat: TerminalHardwareKeyRepeatState<Ghostty.Input.KeyEvent>.Active? {
        guard case .repeating(let active) = hardwareKeyRepeatState.phase else { return nil }
        return active
    }

    private var canContinueHardwareKeyRepeat: Bool {
        canRouteTerminalInput
            && hasHardwareKeyboardAttached
            && isTextInputSessionEligible
            && isTerminalTextInputActive
            && !isPaused
            && !isShuttingDown
    }

    func handleHardwareKeyRepeatTick(token: UUID) {
        guard canContinueHardwareKeyRepeat else {
            cancelTrackedHardwareInput()
            return
        }
        guard let active = hardwareKeyRepeatState.active(for: token), let surface else { return }
        surface.sendKeyEvent(hardwareKeyEvent(active.payload, action: .repeat))
        requestRender()
    }

    @discardableResult
    func endHardwareKeyRepeat(keyCode: UInt16) -> TerminalHardwareKeyRepeatState<Ghostty.Input.KeyEvent>.Active? {
        guard let active = hardwareKeyRepeatState.end(keyCode: keyCode) else { return nil }
        stopHardwareKeyRepeatTimer()
        logKeyboardLifecycle("hardware.repeat.ended", detail: "keyCode=\(keyCode)")
        return active
    }

    func cancelTrackedHardwareInput() {
        stopHardwareKeyRepeatTimer()
        let active = hardwareKeyRepeatState.cancel()
        if let active {
            logKeyboardLifecycle("hardware.repeat.cancelled", detail: "keyCode=\(active.keyCode)")
        }
        var trackedPresses = hardwarePressesSentToGhostty
        hardwarePressesSentToGhostty.removeAll()
        systemTextInputPresses.removeAll()
        terminalAltOptionKeyCodes.removeAll()
        pendingSystemTextInputHardwareKeys.removeAll()

        guard let surface else { return }
        var didSendRelease = false
        if let active {
            trackedPresses.removeValue(forKey: active.keyCode)
            surface.sendKeyEvent(hardwareKeyEvent(active.payload, action: .release))
            didSendRelease = true
        }
        for event in trackedPresses.values {
            surface.sendKeyEvent(hardwareKeyEvent(event, action: .release))
            didSendRelease = true
        }
        if didSendRelease {
            requestRender()
        }
    }

    func hardwareKeyEvent(
        _ event: Ghostty.Input.KeyEvent,
        action: Ghostty.Input.Action,
        text: String? = nil
    ) -> Ghostty.Input.KeyEvent {
        Ghostty.Input.KeyEvent(
            key: event.key,
            action: action,
            text: text ?? event.text,
            composing: false,
            mods: event.mods,
            consumedMods: event.consumedMods,
            unshiftedCodepoint: event.unshiftedCodepoint
        )
    }

    private func fallbackHardwareEvent(
        key: Ghostty.Input.Key,
        action: Ghostty.Input.Action,
        modifiers: UIKeyModifierFlags
    ) -> Ghostty.Input.KeyEvent {
        let mods = Ghostty.Input.Mods(uiKeyModifiers: modifiers)
        let consumedMods = Ghostty.Input.Mods(
            uiKeyModifiers: modifiers.subtracting([.control, .command])
        )
        return .init(
            key: key,
            action: action,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: 0
        )
    }

    private func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        surface cSurface: ghostty_surface_t
    ) -> Ghostty.Input.KeyEvent? {
        let ghosttyAction: Ghostty.Input.Action = switch action {
        case GHOSTTY_ACTION_PRESS: .press
        case GHOSTTY_ACTION_RELEASE: .release
        case GHOSTTY_ACTION_REPEAT: .repeat
        default: .press
        }
        guard let event = Ghostty.Input.KeyEvent(uiKey: key, action: ghosttyAction) else {
            return nil
        }
        guard event.withCValue(execute: { cEvent in
            ghostty_surface_key(cSurface, cEvent)
        }) else { return nil }
        return event
    }

    private func isTextInputModifierOnlyKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardLeftShift,
             .keyboardRightShift,
             .keyboardLeftAlt,
             .keyboardRightAlt:
            return key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty
        default:
            return false
        }
    }

    private func optionKeySide(for key: UIKey) -> TerminalOptionKeySide? {
        switch key.keyCode {
        case .keyboardLeftAlt: .left
        case .keyboardRightAlt: .right
        default: nil
        }
    }

    private func shouldUseOptionKeyAsTerminalAlt(_ key: UIKey) -> Bool {
        guard let side = optionKeySide(for: key) else { return false }
        return TerminalDefaults.optionAsAltMode().usesOptionKeyAsAlt(side)
    }

    private func usesActiveOptionKeyAsTerminalAlt(for key: UIKey) -> Bool {
        guard key.modifierFlags.contains(.alternate) else { return false }
        if optionKeySide(for: key) != nil {
            return shouldUseOptionKeyAsTerminalAlt(key)
        }
        return !terminalAltOptionKeyCodes.isEmpty
    }

    @discardableResult
    private func sendHardwarePressToGhostty(
        _ key: UIKey,
        keyCode: UInt16,
        surface: Ghostty.Surface,
        cSurface: ghostty_surface_t
    ) -> Bool {
        if let event = sendDirectHardwareKeyEvent(
            key,
            action: GHOSTTY_ACTION_PRESS,
            surface: cSurface
        ) {
            hardwarePressesSentToGhostty[keyCode] = event
            registerHardwareKeyRepeat(
                keyCode: keyCode,
                source: .directTerminal,
                event: event,
                isRepeatableSpecialKey: isRepeatableSpecialHardwareKey(key),
                modifiers: key.modifierFlags,
                hasActiveIMEComposition: textInputModel.hasActiveIMEComposition
            )
            return true
        }

        guard let fallbackKey = fallbackHardwareKey(for: key) else {
            return false
        }

        let event = fallbackHardwareEvent(
            key: fallbackKey,
            action: .press,
            modifiers: key.modifierFlags
        )
        surface.sendKeyEvent(event)
        hardwarePressesSentToGhostty[keyCode] = event
        registerHardwareKeyRepeat(
            keyCode: keyCode,
            source: .directTerminal,
            event: event,
            isRepeatableSpecialKey: isRepeatableSpecialHardwareKey(key),
            modifiers: key.modifierFlags,
            hasActiveIMEComposition: textInputModel.hasActiveIMEComposition
        )
        return true
    }

    private func shouldRoutePressToSystemTextInput(_ key: UIKey) -> Bool {
        let keyProducesText = !(key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty)
        if key.keyCode == .keyboardDeleteOrBackspace,
           TerminalHardwareTextInputRoutingPolicy.shouldRouteBackwardDeleteToSystemTextInput(
               inputModeAllowsOneToOneText: TerminalHardwareTextInputRoutingPolicy
                   .inputModeAllowsOneToOneHardwareText(
                       imeProxyTextView.textInputMode?.primaryLanguage
                   ),
               hasLocalTextInputSession: hasLocalTextInputSession,
               hasControlModifier: key.modifierFlags.contains(.control),
               hasAlternateModifier: key.modifierFlags.contains(.alternate),
               hasCommandModifier: key.modifierFlags.contains(.command)
           ) {
            return true
        }
        return TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
            hasControlModifier: key.modifierFlags.contains(.control),
            hasAlternateModifier: key.modifierFlags.contains(.alternate),
            usesAlternateModifierAsTerminalAlt: usesActiveOptionKeyAsTerminalAlt(for: key),
            hasCommandModifier: key.modifierFlags.contains(.command),
            hasActiveIMEComposition: textInputModel.hasActiveIMEComposition,
            isSystemTextInputToggleKey: key.keyCode == .keyboardCapsLock,
            isTextInputModifierOnlyKey: isTextInputModifierOnlyKey(key),
            hasTerminalFallbackKey: fallbackHardwareKey(for: key) != nil,
            keyProducesText: keyProducesText
        )
    }

    private func directlyRoutableHardwareText(for key: UIKey) -> String? {
        TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
            key.characters,
            primaryLanguage: imeProxyTextView.textInputMode?.primaryLanguage,
            hasControlModifier: key.modifierFlags.contains(.control),
            hasAlternateModifier: key.modifierFlags.contains(.alternate),
            hasCommandModifier: key.modifierFlags.contains(.command),
            hasActiveIMEComposition: textInputModel.hasActiveIMEComposition
        )
    }

    func processHardwarePressesBegan(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard let surface = surface, let cSurface = surface.unsafeCValue else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
        guard canRouteTerminalInput else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }

        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            markHardwareKeyboardDetectedFromKeyPress()
            if handlePasteShortcut(key) {
                result.didHandleGhosttyInput = true
                continue
            }
            if handleCommandShortcut(key) { continue }
            if key.modifierFlags.contains(.command) {
                result.forwardedToSystem.insert(press)
                continue
            }
            if isNativeSelectionTextInputContext {
                clearNativeSelectionStateForTerminalInput()
            }
            if textInputModel.hasActiveIMEComposition, key.keyCode == .keyboardEscape {
                invalidateLocalTextInputSession()
                result.didHandleGhosttyInput = true
                continue
            }
            let keyCode = UInt16(key.keyCode.rawValue)
            if shouldUseOptionKeyAsTerminalAlt(key) {
                terminalAltOptionKeyCodes.insert(keyCode)
            }
            if let text = directlyRoutableHardwareText(for: key),
               sendInterpretedHardwareKeyText(
                   text,
                   for: key,
                   repeatSource: .layoutResolvedText
               ) {
                if hasLocalTextInputSession {
                    invalidateLocalTextInputSession()
                }
                result.didHandleGhosttyInput = true
                logKeyboardLifecycle(
                    "hardware.press.handled",
                    detail: "keyCode=\(keyCode) route=layoutResolved"
                )
                continue
            }
            if shouldRoutePressToSystemTextInput(key) {
                let keyProducesText = !(key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty)
                systemTextInputPresses.insert(keyCode)
                if TerminalHardwareTextInputRoutingPolicy.shouldMirrorSystemTextInputModifierPressToTerminal(
                    isTextInputModifierOnlyKey: isTextInputModifierOnlyKey(key)
                ) {
                    // UIKit needs Shift/Option transitions to interpret the next text key, while
                    // Ghostty still needs matching modifier press/release events.
                    if sendHardwarePressToGhostty(
                        key,
                        keyCode: keyCode,
                        surface: surface,
                        cSurface: cSurface
                    ) {
                        result.didHandleGhosttyInput = true
                    }
                    result.forwardedToSystem.insert(press)
                    continue
                }
                if TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                    keyProducesText: keyProducesText,
                    hasControlModifier: key.modifierFlags.contains(.control),
                    hasAlternateModifier: key.modifierFlags.contains(.alternate),
                    hasCommandModifier: key.modifierFlags.contains(.command),
                    hasActiveIMEComposition: textInputModel.hasActiveIMEComposition,
                    isSystemTextInputToggleKey: key.keyCode == .keyboardCapsLock,
                    inputModeAllowsOneToOneText: TerminalHardwareTextInputRoutingPolicy
                        .inputModeAllowsOneToOneHardwareText(
                            imeProxyTextView.textInputMode?.primaryLanguage
                        )
                ) {
                    pendingSystemTextInputHardwareKeys.append(key)
                }
                result.forwardedToSystem.insert(press)
                logKeyboardLifecycle(
                    "hardware.press.forwarded",
                    detail: "keyCode=\(keyCode) route=systemText"
                )
                continue
            }

            if hasLocalTextInputSession {
                invalidateLocalTextInputSession()
            }
            if sendHardwarePressToGhostty(
                key,
                keyCode: keyCode,
                surface: surface,
                cSurface: cSurface
            ) {
                result.didHandleGhosttyInput = true
                logKeyboardLifecycle(
                    "hardware.press.handled",
                    detail: "keyCode=\(keyCode) route=terminal"
                )
            }
        }

        return result
    }

    func processHardwarePressesEnded(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard let surface else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }
        guard canRouteTerminalInput || !hardwarePressesSentToGhostty.isEmpty else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }

        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            let keyCode = UInt16(key.keyCode.rawValue)
            let shouldForwardToSystem = systemTextInputPresses.remove(keyCode) != nil
            terminalAltOptionKeyCodes.remove(keyCode)
            guard let pressedEvent = hardwarePressesSentToGhostty.removeValue(forKey: keyCode) else {
                result.forwardedToSystem.insert(press)
                continue
            }
            endHardwareKeyRepeat(keyCode: keyCode)
            surface.sendKeyEvent(hardwareKeyEvent(pressedEvent, action: .release))
            logKeyboardLifecycle("hardware.press.ended", detail: "keyCode=\(keyCode)")
            result.didHandleGhosttyInput = true
            if shouldForwardToSystem {
                result.forwardedToSystem.insert(press)
            }
        }

        return result
    }

    func processHardwarePressesCancelled(_: Set<UIPress>) {
        logKeyboardLifecycle("hardware.press.cancelled")
        cancelTrackedHardwareInput()
    }

}

#endif
