import Foundation

nonisolated struct RemoteFileTabSnapshot: Codable, Equatable, Sendable {
    var tabsByServer: [String: [RemoteFileTab]]
    var selectedTabByServer: [String: UUID]
    var schemaVersion: Int

    init(
        tabsByServer: [String: [RemoteFileTab]] = [:],
        selectedTabByServer: [String: UUID] = [:],
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.tabsByServer = tabsByServer
        self.selectedTabByServer = selectedTabByServer
        self.schemaVersion = schemaVersion
    }

    static let currentSchemaVersion = 1
}
