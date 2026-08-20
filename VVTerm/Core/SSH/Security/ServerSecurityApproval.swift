import Foundation

nonisolated enum ServerSecurityApprovalRequest: Identifiable, Equatable, Sendable {
    case hostKey(KnownHostsManager.Challenge)

    var id: String {
        switch self {
        case .hostKey(let challenge):
            "host-key:\(challenge.id.uuidString)"
        }
    }

    static func detect(
        _ error: Error,
        host: String,
        port: Int,
        knownHosts: KnownHostsManager
    ) -> Self? {
        if let sshError = error as? SSHError,
           case .hostKeyApprovalRequired = sshError,
           let challenge = knownHosts.pendingChallenge(
               for: host,
               port: port
           ) {
            return .hostKey(challenge)
        }
        return nil
    }
}

nonisolated enum ServerSecurityApprovalError: LocalizedError, Equatable, Sendable {
    case cancelled
    case expired
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "Security approval was cancelled.")
        case .expired:
            String(localized: "Security approval expired. Try again.")
        case .unavailable:
            String(localized: "Security approval is no longer available. Try again.")
        }
    }
}
