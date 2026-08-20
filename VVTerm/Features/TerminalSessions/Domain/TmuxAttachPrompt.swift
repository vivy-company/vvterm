import Foundation

struct TmuxAttachSessionInfo: Identifiable, Equatable {
    let name: String
    let attachedClients: Int
    let windowCount: Int

    var id: String { name }
}

struct TmuxAttachPrompt: Identifiable, Equatable {
    /// Unique shell-start request that owns this prompt.
    let id: UUID
    let paneId: UUID
    let serverId: UUID
    let existingSessions: [TmuxAttachSessionInfo]
}

enum TmuxAttachSelection: Equatable {
    case createManaged
    case attachExisting(sessionName: String)
    case skipTmux
}
