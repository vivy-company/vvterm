import Foundation

nonisolated enum SSHConnectedSessionAction: Equatable, Sendable {
    case reuse
    case recover
    case reject
}

nonisolated enum SSHConnectedSessionPolicy {
    static func action(
        existingConnectionKey: String,
        requestedConnectionKey: String,
        transportIsConnected: Bool
    ) -> SSHConnectedSessionAction {
        guard transportIsConnected else { return .recover }
        return existingConnectionKey == requestedConnectionKey ? .reuse : .reject
    }
}
