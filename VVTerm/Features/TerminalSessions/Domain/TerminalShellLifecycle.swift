import Foundation

nonisolated struct TmuxShellLifecycleContext: Hashable, Sendable {
    let ownership: TmuxSessionOwnership
    let markerToken: String
    let presenceProbe: TmuxSessionPresenceProbe
}

nonisolated struct EternalTerminalTmuxResumeContext: Codable, Hashable, Sendable {
    let ownership: TmuxSessionOwnership
    let markerToken: String
}

nonisolated struct TmuxSessionPresenceProbe: Hashable, Sendable {
    let command: String
    let existsMarker: String
    let missingMarker: String

    nonisolated func sessionExists(in output: String) -> Bool? {
        if output.contains(existsMarker) {
            return true
        }
        if output.contains(missingMarker) {
            return false
        }
        return nil
    }
}

nonisolated struct TerminalShellStartupPlan: Sendable {
    let command: String?
    let tmuxLifecycle: TmuxShellLifecycleContext?

    nonisolated static let plainShell = TerminalShellStartupPlan(
        command: nil,
        tmuxLifecycle: nil
    )
}

nonisolated enum TerminalShellEndReason: Hashable, Sendable {
    case transportEnded
    case tmuxDetached(TmuxSessionOwnership)
    case tmuxEnded(TmuxSessionOwnership)
    case tmuxCreationFailed

    nonisolated static func resolve(
        tmuxLifecycle: TmuxShellLifecycleContext?,
        markerEvent: TmuxLifecycleEvent?,
        sessionExists: Bool?
    ) -> Self {
        guard let tmuxLifecycle else {
            return .transportEnded
        }

        switch markerEvent {
        case .detached:
            return .tmuxDetached(tmuxLifecycle.ownership)
        case .ended:
            return .tmuxEnded(tmuxLifecycle.ownership)
        case .creationFailed:
            return .tmuxCreationFailed
        case nil:
            switch sessionExists {
            case true:
                return .tmuxDetached(tmuxLifecycle.ownership)
            case false:
                return .tmuxEnded(tmuxLifecycle.ownership)
            case nil:
                return .transportEnded
            }
        }
    }
}

nonisolated enum TerminalDisconnectReason: String, Codable, Hashable, Sendable {
    case transportEnded
    case tmuxDetached
    case externalTmuxEnded

    var allowsAutomaticReconnect: Bool {
        self == .transportEnded
    }
}

nonisolated enum TerminalTeardownIntent: CaseIterable, Sendable {
    case explicitClose
    case explicitServerDisconnect
    case remoteSessionEnded
    case applicationTermination

    var removesPersistedDescriptor: Bool {
        self != .applicationTermination
    }

    var terminatesManagedTmux: Bool {
        switch self {
        case .explicitClose, .explicitServerDisconnect:
            true
        case .remoteSessionEnded, .applicationTermination:
            false
        }
    }

    var deletesResumableSessionState: Bool {
        self != .applicationTermination
    }
}
