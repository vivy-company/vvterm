import Foundation

struct TmuxAttachSessionInfo: Identifiable, Equatable {
    let name: String
    let attachedClients: Int
    let windowCount: Int

    var id: String { name }
}

struct TmuxAttachPrompt: Identifiable, Equatable {
    /// Session ID (ConnectionSession.id or Terminal paneId) that is waiting for selection.
    let id: UUID
    let serverId: UUID
    let serverName: String
    let existingSessions: [TmuxAttachSessionInfo]
}

enum TmuxAttachSelection: Equatable {
    case createManaged
    case attachExisting(sessionName: String)
    case skipTmux
}
