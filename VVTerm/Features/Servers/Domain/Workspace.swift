import Foundation

// MARK: - Workspace Model

nonisolated struct Workspace: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var icon: String?
    var order: Int
    var environments: [ServerEnvironment]
    var lastSelectedEnvironmentId: UUID?
    var lastSelectedServerId: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#007AFF",
        icon: String? = nil,
        order: Int = 0,
        environments: [ServerEnvironment] = ServerEnvironment.builtInEnvironments,
        lastSelectedEnvironmentId: UUID? = nil,
        lastSelectedServerId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.order = order
        self.environments = environments
        self.lastSelectedEnvironmentId = lastSelectedEnvironmentId
        self.lastSelectedServerId = lastSelectedServerId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func environment(withId id: UUID) -> ServerEnvironment? {
        environments.first { $0.id == id }
    }

    func containsEnvironment(_ candidate: ServerEnvironment) -> Bool {
        environment(withId: candidate.id) != nil
    }

}
