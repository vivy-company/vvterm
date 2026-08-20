import Foundation

nonisolated enum ShellTransport: String, Codable, Hashable, Sendable {
    case ssh
    case mosh
    case eternalTerminal
    case sshFallback
}

nonisolated enum MoshFallbackReason: String, Codable, Hashable, Sendable {
    case serverMissing
    case serverRuntimeBroken
    case bootstrapFailed
    case sessionFailed
    case unsupportedRemoteCapabilities
    case invalidEndpoint
    case udpTimeout
    case clientSessionFailed

    var bannerMessage: String {
        switch self {
        case .serverMissing:
            return String(localized: "Using SSH fallback for this session (mosh-server is missing).")
        case .serverRuntimeBroken:
            return String(localized: "Using SSH fallback for this session (mosh-server is installed but cannot run).")
        case .unsupportedRemoteCapabilities:
            return String(localized: "Using SSH fallback for this session (Mosh is not supported by the resolved remote environment).")
        case .bootstrapFailed:
            return String(localized: "Using SSH fallback for this session (mosh-server could not start correctly).")
        case .invalidEndpoint:
            return String(localized: "Using SSH fallback for this session (the Mosh server address was invalid).")
        case .udpTimeout:
            return String(localized: "Using SSH fallback for this session (the Mosh UDP connection timed out; check UDP ports 60001–61000).")
        case .clientSessionFailed:
            return String(localized: "Using SSH fallback for this session (the Mosh client session could not start).")
        case .sessionFailed:
            return String(localized: "Using SSH fallback for this session.")
        }
    }
}

nonisolated enum MoshServerMaintenanceAction: Equatable, Sendable {
    case install
    case repair
}

nonisolated enum ShellTransportState: Equatable, Sendable {
    case ssh
    case mosh
    case eternalTerminal
    case sshFallback(reason: MoshFallbackReason, diagnostics: MoshFallbackDiagnostics?)

    var transport: ShellTransport {
        switch self {
        case .ssh:
            return .ssh
        case .mosh:
            return .mosh
        case .eternalTerminal:
            return .eternalTerminal
        case .sshFallback:
            return .sshFallback
        }
    }

    var fallbackReason: MoshFallbackReason? {
        guard case .sshFallback(let reason, _) = self else { return nil }
        return reason
    }

    var fallbackDiagnostics: MoshFallbackDiagnostics? {
        guard case .sshFallback(_, let diagnostics) = self else { return nil }
        return diagnostics
    }

    var moshServerMaintenanceAction: MoshServerMaintenanceAction? {
        guard case .sshFallback(let reason, _) = self else { return nil }
        switch reason {
        case .serverMissing:
            return .install
        case .serverRuntimeBroken:
            return .repair
        case .bootstrapFailed, .sessionFailed, .unsupportedRemoteCapabilities,
             .invalidEndpoint, .udpTimeout, .clientSessionFailed:
            return nil
        }
    }

    mutating func clearFallbackDiagnostics() {
        guard case .sshFallback(let reason, _) = self else { return }
        self = .sshFallback(reason: reason, diagnostics: nil)
    }
}

nonisolated enum MoshEndpointCandidatePolicy {
    static func hosts(configuredHost: String, sshPeerHost: String?) -> [String] {
        let configured = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return [] }
        var result = [configured]
        if let peer = sshPeerHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !peer.isEmpty,
           peer != configured {
            result.append(peer)
        }
        return result
    }
}
