import Foundation

struct TmuxAttachPrompt: Identifiable, Equatable {
    /// Session ID (ConnectionSession.id or Terminal paneId) that is waiting for selection.
    let id: UUID
    let serverId: UUID
    let serverName: String
    let existingSessionNames: [String]
}

enum TmuxAttachSelection: Equatable {
    case createManaged
    case attachExisting(sessionName: String)
    case skipTmux
}
