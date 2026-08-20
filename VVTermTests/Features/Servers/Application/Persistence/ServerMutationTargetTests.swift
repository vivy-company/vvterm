import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerMutationTargetTests {
    private let repository = ServerMutationCommandRepository()

    @Test
    func deletedServerCannotBeUpdatedFromAStaleForm() {
        let deletedServer = Server(
            workspaceId: UUID(),
            name: "Deleted",
            host: "deleted.example.com",
            username: "root"
        )

        #expect(throws: VVTermError.self) {
            try repository.existingServerIndex(for: deletedServer.id, in: [])
        }
    }

    @Test
    func deletedWorkspaceCannotBeUpdatedFromAStaleForm() {
        let deletedWorkspace = Workspace(name: "Deleted", order: 0)

        #expect(throws: VVTermError.self) {
            try repository.existingWorkspaceIndex(for: deletedWorkspace.id, in: [])
        }
    }

    @Test
    func existingEntitiesResolveTheirCurrentIndex() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Current",
            host: "current.example.com",
            username: "root"
        )
        let workspace = Workspace(name: "Current", order: 0)

        #expect(try repository.existingServerIndex(for: server.id, in: [server]) == 0)
        #expect(try repository.existingWorkspaceIndex(for: workspace.id, in: [workspace]) == 0)
    }
}
