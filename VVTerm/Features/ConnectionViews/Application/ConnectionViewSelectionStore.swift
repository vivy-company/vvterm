import Combine
import Foundation

/// Owns the selected connection surface for each server.
@MainActor
final class ConnectionViewSelectionStore: ObservableObject {
    @Published private(set) var selectionsByServer: [UUID: ConnectionViewTabID] = [:]

    func selection(for serverId: UUID) -> ConnectionViewTabID? {
        selectionsByServer[serverId]
    }

    func setSelection(_ selection: ConnectionViewTabID?, for serverId: UUID) {
        guard selectionsByServer[serverId] != selection else { return }
        if let selection {
            selectionsByServer[serverId] = selection
        } else {
            selectionsByServer.removeValue(forKey: serverId)
        }
    }

    func restore(_ selections: [UUID: ConnectionViewTabID]) {
        selectionsByServer = selections
    }

    #if DEBUG
    func resetForTesting() {
        selectionsByServer.removeAll()
    }
    #endif
}
