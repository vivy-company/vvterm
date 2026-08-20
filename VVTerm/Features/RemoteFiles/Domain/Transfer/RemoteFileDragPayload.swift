import Foundation

nonisolated struct RemoteFileDragPayload: Codable, Equatable, Sendable {
    let serverId: UUID
    let entries: [RemoteFileEntry]

    init(serverId: UUID, entry: RemoteFileEntry) {
        self.init(serverId: serverId, entries: [entry])
    }

    init(serverId: UUID, entries: [RemoteFileEntry]) {
        self.serverId = serverId
        self.entries = entries
    }
}
