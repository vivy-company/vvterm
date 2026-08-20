import Foundation

// MARK: - Connection State

nonisolated enum TerminalConnectionRetryDisposition: Hashable, Sendable {
    case automatic
    case manual
}

nonisolated enum TerminalConnectionRequiredAction: Hashable, Sendable {
    case approveHostKey
}

nonisolated enum TerminalConnectionFailure: Hashable, Sendable {
    case reconnectTimedOut
    case tmuxStartupFailed
    case eternalTerminal(
        failure: EternalTerminalSessionFailure,
        host: String,
        port: Int
    )
    case external(
        message: String,
        retryDisposition: TerminalConnectionRetryDisposition,
        requiredAction: TerminalConnectionRequiredAction?
    )

    var allowsAutomaticReconnectRetry: Bool {
        switch self {
        case .external(_, let retryDisposition, _):
            return retryDisposition == .automatic
        case .reconnectTimedOut, .tmuxStartupFailed, .eternalTerminal:
            return false
        }
    }

    var requiredAction: TerminalConnectionRequiredAction? {
        switch self {
        case .external(_, _, let requiredAction):
            return requiredAction
        case .reconnectTimedOut, .tmuxStartupFailed, .eternalTerminal:
            return nil
        }
    }
}

nonisolated enum TerminalTabOpeningError: Error, Equatable, Sendable {
    case alreadyOpening
}

nonisolated enum ConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(TerminalConnectionFailure)
    case idle

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

}

nonisolated enum TerminalConnectionAttemptPolicy {
    static func state(attempt: Int, hasEstablishedConnection: Bool) -> ConnectionState {
        if hasEstablishedConnection || attempt > 1 {
            return .reconnecting(attempt: attempt)
        }
        return .connecting
    }
}
