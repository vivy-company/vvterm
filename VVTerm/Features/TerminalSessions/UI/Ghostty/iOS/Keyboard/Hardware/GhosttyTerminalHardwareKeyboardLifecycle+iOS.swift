//
//  GhosttyTerminalHardwareKeyboardLifecycle+iOS.swift
//  VVTerm
//
//  iOS terminal hardware-keyboard observation and attachment lifecycle.
//

#if os(iOS)
import GameController
import UIKit

extension GhosttyTerminalView {
    func setupHardwareKeyboardObservation() {
        guard hardwareKeyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
                }
            }
        )
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
                }
            }
        )
        updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
    }

    func removeHardwareKeyboardObservers() {
        for observer in hardwareKeyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        hardwareKeyboardObservers.removeAll()
    }

    func refreshHardwareKeyboardAttachmentFromSystem() {
        let hasHardwareKeyboard = detectedHardwareKeyboardAttached
        let previousInputConfiguration = terminalInputConfiguration
        if setHardwareKeyboardAttached(hasHardwareKeyboard) {
            notifyKeyboardBrowseModeChange(
                previousInputConfiguration: previousInputConfiguration
            )
        }
    }

    func updateHardwareKeyboardState(reloadInputViewsIfNeeded: Bool) {
        let hasHardwareKeyboard = detectedHardwareKeyboardAttached
        let previousInputConfiguration = terminalInputConfiguration
        let didChange = setHardwareKeyboardAttached(hasHardwareKeyboard)
        if didChange {
            logKeyboardLifecycle(
                "hardware.changed",
                detail: "attached=\(hasHardwareKeyboard) vendor=\(GCKeyboard.coalesced?.vendorName ?? "nil")"
            )
        }
        if didChange {
            notifyKeyboardBrowseModeChange(
                previousInputConfiguration: previousInputConfiguration
            )
        }
        if hasHardwareKeyboard {
            focusForHardwareKeyboardIfNeeded()
        } else if didChange {
            if isTerminalTextInputActive, isTextInputSessionEligible, !isFindNavigatorActive {
                _ = requestKeyboardFocus(for: .initialActivation)
            }
        }
        if reloadInputViewsIfNeeded,
           previousInputConfiguration == terminalInputConfiguration,
           isTerminalTextInputActive,
           isTextInputSessionEligible {
            reloadTerminalInputViewsIfActive()
        }
    }

    @discardableResult
    func setHardwareKeyboardAttached(_ attached: Bool) -> Bool {
        guard attached != hasHardwareKeyboardAttached else { return false }
        if !attached {
            cancelTrackedHardwareInput()
        }
        hasHardwareKeyboardAttached = attached
        return true
    }

    func markHardwareKeyboardDetectedFromKeyPress() {
        #if DEBUG
        if keyboardUITestHardwareKeyboardOverride == false { return }
        #endif
        guard !hasHardwareKeyboardAttached else { return }
        let previousInputConfiguration = terminalInputConfiguration
        hasHardwareKeyboardAttached = true
        notifyKeyboardBrowseModeChange(
            previousInputConfiguration: previousInputConfiguration
        )
        focusForHardwareKeyboardIfNeeded()
    }

    private var detectedHardwareKeyboardAttached: Bool {
        #if DEBUG
        if let keyboardUITestHardwareKeyboardOverride {
            return keyboardUITestHardwareKeyboardOverride
        }
        #endif
        return GCKeyboard.coalesced != nil
    }
}

#endif
