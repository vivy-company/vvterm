//
//  GhosttyTerminalAccessoryPresentation+iOS.swift
//  VVTerm
//
//  iOS terminal keyboard accessory presentation.
//

#if os(iOS)
import UIKit

// MARK: - Keyboard Accessory View

extension GhosttyTerminalView {
    var shouldHideKeyboardAccessoryBar: Bool {
        terminalInputConfiguration != .systemWithAccessory
    }

    func resolvedInputAccessoryView() -> UIView? {
        guard !shouldHideKeyboardAccessoryBar else {
            return nil
        }
        if keyboardToolbar == nil {
            let toolbar = TerminalInputAccessoryView(
                terminalOwner: self,
                inputSnapshot: terminalAccessoryInputSnapshot,
                onKey: { [weak self] key in
                    self?.handleToolbarKey(key)
                },
                onCustomAction: { [weak self] action in
                    self?.handleToolbarCustomAction(action)
                },
                onVoice: onVoiceButtonTapped,
                onDismissKeyboard: { [weak self] in
                    self?.dismissKeyboardFromToolbar()
                }
            )
            keyboardToolbar = toolbar
        } else {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
        return keyboardToolbar
    }

    func applyTerminalAccessoryInputSnapshot(_ snapshot: TerminalAccessoryInputSnapshot) {
        guard snapshot != terminalAccessoryInputSnapshot else { return }
        terminalAccessoryInputSnapshot = snapshot
        keyboardToolbar?.apply(snapshot)
    }

    func refreshTerminalInputAccessoryAppearance() {
        keyboardToolbar?.refreshAppearance()
    }

    private func handleToolbarKey(_ key: TerminalKey) {
        sendToolbarKey(key)
    }
}

#endif
