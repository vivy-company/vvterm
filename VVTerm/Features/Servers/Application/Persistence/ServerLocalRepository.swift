import Foundation

nonisolated struct ServerLocalStorageIssue: Identifiable, Equatable, Sendable {
    nonisolated enum Collection: String, Equatable, Sendable {
        case servers
        case workspaces
    }

    let collection: Collection
    let quarantineKey: String

    var id: Collection { collection }
}

nonisolated enum ServerLocalLoadResult<Value> {
    case missing
    case loaded(Value)
    case unreadable(ServerLocalStorageIssue)
}

nonisolated struct ServerLocalRepositorySnapshot {
    let servers: ServerLocalLoadResult<[Server]>
    let workspaces: ServerLocalLoadResult<[Workspace]>
}

@MainActor
protocol ServerLocalRepository: ServerDataMutationJournalStoring {
    func loadSnapshot() -> ServerLocalRepositorySnapshot
    func persist(servers: [Server], workspaces: [Workspace]) throws
    func clearServerData() throws
    func loadAmbiguousCloudRecoveryBackup() throws -> AmbiguousCloudRecoveryBackup?
    func storeAmbiguousCloudRecoveryBackup(_ backup: AmbiguousCloudRecoveryBackup) throws
    func clearAmbiguousCloudRecoveryBackup() throws
}
