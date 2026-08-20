nonisolated enum TerminalKeyboardFocusReason: Sendable {
    case explicitUserRequest
    case initialActivation
    case reconnectRestore
    case directTouch
    case selectionGesture
    case hardwareKeyboard
}

nonisolated struct TerminalKeyboardFocusPolicy: Sendable {
    nonisolated private enum Mode: Sendable {
        case automaticTyping(restoreOnReconnect: Bool)
        case forcedSoftwareTyping
        case browse
    }

    private var mode: Mode = .automaticTyping(restoreOnReconnect: false)

    var allowsAutomaticFocus: Bool {
        if case .browse = mode {
            return false
        }
        return true
    }

    var isBrowsing: Bool {
        if case .browse = mode {
            return true
        }
        return false
    }

    var shouldRestoreOnReconnect: Bool {
        switch mode {
        case .automaticTyping(let restoreOnReconnect):
            return restoreOnReconnect
        case .forcedSoftwareTyping:
            return true
        case .browse:
            return false
        }
    }

    var forcesSoftwareKeyboardPresentation: Bool {
        if case .forcedSoftwareTyping = mode {
            return true
        }
        return false
    }

    func shouldSuppressSoftwareKeyboard(hasHardwareKeyboardAttached: Bool) -> Bool {
        isBrowsing || (hasHardwareKeyboardAttached && !forcesSoftwareKeyboardPresentation)
    }

    mutating func requestFocus(for reason: TerminalKeyboardFocusReason) -> Bool {
        switch reason {
        case .explicitUserRequest:
            mode = .forcedSoftwareTyping
            return true
        case .initialActivation, .directTouch, .selectionGesture, .hardwareKeyboard:
            switch mode {
            case .automaticTyping:
                mode = .automaticTyping(restoreOnReconnect: true)
                return true
            case .forcedSoftwareTyping:
                return true
            case .browse:
                return false
            }
        case .reconnectRestore:
            return shouldRestoreOnReconnect
        }
    }

    mutating func dismissForUser() {
        mode = .browse
    }
}
