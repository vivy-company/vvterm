//
//  GhosttyTerminalTextInput+iOS.swift
//  VVTerm
//
//  iOS terminal text-input delegate routing.
//

#if os(iOS)
import UIKit
import os

extension GhosttyTerminalView {

    func consumePendingSystemTextInputHardwareKey() -> UIKey? {
        guard !pendingSystemTextInputHardwareKeys.isEmpty else { return nil }
        return pendingSystemTextInputHardwareKeys.removeFirst()
    }

    func cancelHardwareKeyRepeatForIMEComposition() {
        cancelTrackedHardwareInput()
    }

    func removeUnconsumedPendingSystemTextInputHardwareKeys(after pendingCount: Int) {
        guard pendingSystemTextInputHardwareKeys.count > pendingCount else { return }
        pendingSystemTextInputHardwareKeys.removeSubrange(pendingCount...)
    }

    @discardableResult
    func sendInterpretedHardwareKeyText(
        _ text: String,
        for key: UIKey,
        repeatSource: TerminalHardwareKeyRepeatSource = .systemInterpretedText
    ) -> Bool {
        guard let sourceEvent = Ghostty.Input.KeyEvent(uiKey: key, action: .press) else {
            sendText(text)
            return true
        }
        return sendResolvedInterpretedHardwareKeyText(
            text,
            keyCode: UInt16(key.keyCode.rawValue),
            modifiers: key.modifierFlags,
            sourceEvent: sourceEvent,
            repeatSource: repeatSource
        )
    }

    @discardableResult
    func sendResolvedInterpretedHardwareKeyText(
        _ text: String,
        keyCode: UInt16,
        modifiers: UIKeyModifierFlags,
        sourceEvent: Ghostty.Input.KeyEvent,
        repeatSource: TerminalHardwareKeyRepeatSource
    ) -> Bool {
        guard canRouteTerminalInput, let surface else { return false }
        let interpretedEvent = Ghostty.Input.KeyEvent(
            key: sourceEvent.key,
            action: .press,
            text: text.isEmpty ? sourceEvent.text : text,
            composing: false,
            mods: sourceEvent.mods,
            consumedMods: sourceEvent.consumedMods,
            unshiftedCodepoint: sourceEvent.unshiftedCodepoint
        )
        let registration = registerHardwareKeyRepeat(
            keyCode: keyCode,
            source: repeatSource,
            event: interpretedEvent,
            isRepeatableSpecialKey: false,
            modifiers: modifiers,
            hasActiveIMEComposition: textInputModel.hasActiveIMEComposition
        )
        if case .updated? = registration {
            hardwarePressesSentToGhostty[keyCode] = interpretedEvent
            return true
        }

        surface.sendKeyEvent(interpretedEvent)
        hardwarePressesSentToGhostty[keyCode] = interpretedEvent
        requestRender()
        return true
    }

    func updateActiveInterpretedHardwareKeyRepeat(text: String) -> Bool {
        guard !text.isEmpty,
              let active = activeHardwareKeyRepeat,
              systemTextInputPresses.contains(active.keyCode) else {
            return false
        }
        let event = hardwareKeyEvent(active.payload, action: .press, text: text)
        hardwareKeyRepeatState.register(
            keyCode: active.keyCode,
            payload: event
        )
        hardwarePressesSentToGhostty[active.keyCode] = event
        return true
    }

    var isNativeSelectionTextInputContext: Bool {
        usesNativeTouchSelection
            && (
                isFindNavigatorActive
                    || (
                        allowsHostTextSelection
                            && (
                                nativeSelectionInteractionActive
                                    || nativeSelectedRange != nil
                                    || prefersNativeSelectionFirstResponder
                            )
                    )
            )
    }
}


extension GhosttyTerminalView {
    func setupInputModeObservation() {
        inputModeObserver = NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentInputModeDidChange()
            }
        }
    }

    private func handleCurrentInputModeDidChange() {
        guard !isShuttingDown else { return }
        TerminalIMEProxyTextView.dictationLogger.log("inputModeDidChange primary=\(self.currentIMEPrimaryLanguage ?? "nil", privacy: .public) terminalFirstResponder=\(self.isTerminalTextInputActive) session=\(self.imeProxyTextView.isDictationSessionActive)")
        if isDictationInputModeActive {
            // Entering dictation. Invalidating the session or reloading input views here
            // would terminate dictation immediately after it starts.
            if imeProxyTextView.isFirstResponder {
                imeProxyTextView.beginDictationSession()
            }
            return
        }
        if imeProxyTextView.isDictationSessionActive {
            // Leaving dictation: commit what was dictated to the terminal.
            imeProxyTextView.endDictationSession(commit: true)
            return
        }
        invalidateLocalTextInputSession()
        guard isTerminalTextInputActive, isTextInputSessionEligible else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.reloadTerminalInputViewsIfActive()
        }
    }

    private var isDictationInputModeActive: Bool {
        TerminalVisiblePreeditPolicy.isDictationInputMode(currentIMEPrimaryLanguage)
    }
}

#endif
