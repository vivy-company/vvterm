import Foundation
import Testing
@testable import VVTerm

struct ServerMovePolicyTests {
    @Test
    func proCanMoveToEveryOtherWorkspaceInOrder() {
        let first = workspace(1, order: 2)
        let second = workspace(2, order: 0)
        let third = workspace(3, order: 1)
        let server = server(in: first)
        let policy = ServerMovePolicy(
            workspaces: [first, second, third],
            unlockedWorkspaceIDs: [],
            hasProAccess: true
        )

        #expect(policy.moveDestinations(for: server).map(\.id) == [second.id, third.id])
        #expect(policy.assignmentWorkspaces(for: server).map(\.id) == [second.id, third.id, first.id])
    }

    @Test
    func lockedSourceCanMoveBackToAnUnlockedWorkspace() {
        let unlocked = workspace(1, order: 0)
        let locked = workspace(2, order: 1)
        let server = server(in: locked)
        let policy = ServerMovePolicy(
            workspaces: [locked, unlocked],
            unlockedWorkspaceIDs: [unlocked.id],
            hasProAccess: false
        )

        #expect(policy.moveDestinations(for: server).map(\.id) == [unlocked.id])
        #expect(policy.canAssign(server, to: unlocked))
        #expect(policy.restriction(for: server, destination: unlocked) == nil)
    }

    @Test
    func lockedDestinationReportsTheFreeTierRestriction() {
        let unlocked = workspace(1, order: 0)
        let locked = workspace(2, order: 1)
        let server = server(in: unlocked)
        let policy = ServerMovePolicy(
            workspaces: [unlocked, locked],
            unlockedWorkspaceIDs: [unlocked.id],
            hasProAccess: false
        )

        #expect(!policy.canAssign(server, to: locked))
        #expect(policy.restriction(for: server, destination: locked) == .lockedWorkspace)
        #expect(policy.restriction(for: server, destination: unlocked) == nil)
    }

    @Test
    func unknownDestinationIsUnavailableForPro() {
        let source = workspace(1, order: 0)
        let missing = workspace(2, order: 1)
        let server = server(in: source)
        let policy = ServerMovePolicy(
            workspaces: [source],
            unlockedWorkspaceIDs: [source.id],
            hasProAccess: true
        )

        #expect(policy.restriction(for: server, destination: missing) == .unavailable)
    }

    private func workspace(_ id: Int, order: Int) -> Workspace {
        Workspace(
            id: fixedID(id),
            name: "Workspace \(id)",
            order: order,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func server(in workspace: Workspace) -> Server {
        Server(
            id: fixedID(99),
            workspaceId: workspace.id,
            name: "Server",
            host: "server.example.test",
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func fixedID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
