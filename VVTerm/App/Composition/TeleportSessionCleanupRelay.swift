import Foundation

@MainActor
final class TeleportSessionCleanupRelay {
    weak var servers: ServerManager?
    weak var tabs: TerminalTabManager?

    func disconnect(profileID: String) {
        for server in servers?.servers ?? [] where server.teleportConfiguration?.profile.identifier == profileID {
            tabs?.disconnectServer(server.id)
        }
    }
}
