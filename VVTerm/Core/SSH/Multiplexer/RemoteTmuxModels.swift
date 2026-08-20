import Foundation

nonisolated struct RemoteTmuxSession: Hashable, Sendable {
    let name: String
    let attachedClients: Int
    let windowCount: Int
}

nonisolated enum TmuxSessionOwnership: String, Codable, Hashable, Sendable {
    case managed
    case external
}

nonisolated struct RemoteTmuxThemeStyle: Equatable, Sendable {
    let name: String
    let modeStyle: String
}

nonisolated enum RemoteTmuxBackend: Hashable, Sendable {
    case unixTmux
    case windowsPsmux(
        commandName: String,
        shellFamily: RemoteShellFamily,
        powerShellExecutable: String?
    )

    var isWindows: Bool {
        if case .windowsPsmux = self {
            return true
        }
        return false
    }
}

nonisolated enum RemoteTmuxProbeFailure: Hashable, Sendable {
    case cancelled
    case timeout
    case disconnected
    case transport(String)
    case channelOpenFailed
    case shellRequestFailed
    case invalidResponse
    case commandFailed(String)

    var retryError: Error {
        switch self {
        case .cancelled:
            return CancellationError()
        case .timeout:
            return SSHError.timeout
        case .disconnected:
            return SSHError.notConnected
        case .transport(let message):
            return SSHError.socketError(message)
        case .channelOpenFailed:
            return SSHError.channelOpenFailed
        case .shellRequestFailed:
            return SSHError.shellRequestFailed
        case .invalidResponse:
            return SSHError.unknown("Unable to verify tmux availability")
        case .commandFailed(let message):
            return SSHError.unknown(message)
        }
    }

    static func resolve(_ error: Error) -> Self {
        if error is CancellationError {
            return .cancelled
        }
        guard let sshError = error as? SSHError else {
            return .commandFailed(error.localizedDescription)
        }
        switch sshError {
        case .timeout:
            return .timeout
        case .notConnected:
            return .disconnected
        case .connectionFailed(let message), .socketError(let message):
            return .transport(message)
        case .channelOpenFailed:
            return .channelOpenFailed
        case .shellRequestFailed:
            return .shellRequestFailed
        default:
            return .commandFailed(sshError.localizedDescription)
        }
    }

    var logDescription: String {
        switch self {
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .disconnected: return "disconnected"
        case .transport: return "transport failure"
        case .channelOpenFailed: return "channel open failure"
        case .shellRequestFailed: return "shell request failure"
        case .invalidResponse: return "invalid response"
        case .commandFailed: return "command failure"
        }
    }
}

nonisolated enum RemoteTmuxAvailability: Hashable, Sendable {
    case unsupported
    case available(RemoteTmuxBackend)
    case confirmedMissing
    case indeterminate(RemoteTmuxProbeFailure)

    var backend: RemoteTmuxBackend? {
        guard case .available(let backend) = self else { return nil }
        return backend
    }

    var logDescription: String {
        switch self {
        case .unsupported: return "unsupported"
        case .available(let backend): return "available (\(String(describing: backend)))"
        case .confirmedMissing: return "confirmed missing"
        case .indeterminate(let failure): return "indeterminate (\(failure.logDescription))"
        }
    }
}
