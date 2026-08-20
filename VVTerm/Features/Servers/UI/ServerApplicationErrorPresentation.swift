import Foundation

extension ServerConnectionTestFailure {
    nonisolated var message: String {
        switch reason {
        case .message(let message):
            return message
        case .tailscale(let message):
            let reminder = String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback).")
            return message.contains(reminder) ? message : "\(message)\n\(reminder)"
        case .eternalTerminal(let failure, let host, let port):
            return TerminalConnectionFailurePresentation.message(
                for: .eternalTerminal(
                    failure: failure,
                    host: host,
                    port: port
                )
            )
        case .hostKeyApprovalExpired:
            return String(localized: "SSH host key approval expired. Try again.")
        }
    }
}

extension VVTermError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .proRequired(let requirement):
            switch requirement {
            case .unlimitedServers:
                return String(localized: "Upgrade to Pro for unlimited servers")
            case .unlimitedWorkspaces:
                return String(localized: "Upgrade to Pro for unlimited workspaces")
            case .moveIntoLockedWorkspace:
                return String(localized: "Upgrade to Pro to move servers into locked workspaces")
            }
        case .serverLocked(let serverName):
            return String(format: String(localized: "Server '%@' is locked"), serverName)
        case .workspaceLocked(let workspaceName):
            return String(format: String(localized: "Workspace '%@' is locked"), workspaceName)
        case .moveNotAllowed(let reason):
            switch reason {
            case .destinationUnavailable:
                return String(localized: "The destination workspace is no longer available.")
            case .unavailable:
                return String(localized: "This server can't be moved to that workspace right now.")
            }
        case .connectionFailed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
        case .authenticationFailed:
            return String(localized: "Authentication failed")
        case .authorizationRequired:
            return String(localized: "Authorization is required")
        case .serverNotFound:
            return String(localized: "Server no longer exists.")
        case .serverDataMutationRecoveryPending:
            return String(localized: "The server data change is still being recovered. Try again after recovery completes.")
        case .workspaceNotFound:
            return String(localized: "Workspace no longer exists.")
        case .environmentNotFound:
            return String(localized: "Environment no longer exists.")
        case .environmentDeletionNotAllowed:
            return String(localized: "Built-in environments cannot be deleted.")
        case .environmentFallbackUnavailable:
            return String(localized: "The fallback environment is not available.")
        case .workspaceDeletionChanged:
            return String(localized: "The workspace changed while deletion was authorized. Review it and try again.")
        case .timeout:
            return String(localized: "Connection timed out")
        }
    }
}
