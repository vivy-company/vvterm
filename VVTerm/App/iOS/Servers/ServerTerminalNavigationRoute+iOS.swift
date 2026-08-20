import Foundation

#if os(iOS)
nonisolated enum ServerTerminalNavigationRoute: Equatable, Sendable {
    nonisolated enum ConnectionResolution: Sendable {
        case succeeded
        case failed
    }

    case connecting(server: Server, attemptID: UUID)
    case active(serverId: UUID)

    var serverId: UUID {
        switch self {
        case .connecting(let server, _):
            server.id
        case .active(let serverId):
            serverId
        }
    }

    var connectingServer: Server? {
        guard case .connecting(let server, _) = self else { return nil }
        return server
    }

    var connectionAttemptID: UUID? {
        guard case .connecting(_, let attemptID) = self else { return nil }
        return attemptID
    }

    var isConnecting: Bool {
        connectingServer != nil
    }

    func resolvingConnection(
        for attemptID: UUID,
        as resolution: ConnectionResolution
    ) -> Self? {
        guard case .connecting(let server, let currentAttemptID) = self,
              currentAttemptID == attemptID else {
            return self
        }

        switch resolution {
        case .succeeded:
            return .active(serverId: server.id)
        case .failed:
            return nil
        }
    }
}
#endif
