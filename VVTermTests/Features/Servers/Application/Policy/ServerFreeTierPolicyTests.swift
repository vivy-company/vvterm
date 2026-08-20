import Foundation
import Testing
@testable import VVTerm

struct ServerFreeTierPolicyTests {
    @Test
    func currentAndLegacyPlansUseTheirExplicitLimits() {
        let current = ServerFreeTierPolicy(generation: .currentOneServer)
        let legacy = ServerFreeTierPolicy(generation: .legacyThreeServers)

        #expect(current.serverLimit == 1)
        #expect(!current.canAddServer(serverCount: 1, hasProAccess: false))
        #expect(legacy.serverLimit == 3)
        #expect(legacy.canAddServer(serverCount: 2, hasProAccess: false))
        #expect(!legacy.canAddServer(serverCount: 3, hasProAccess: false))
        #expect(legacy.canAddServer(serverCount: Int.max, hasProAccess: true))
    }

    @Test
    func freeTierUnlocksOldestServersAndFirstWorkspace() {
        let firstWorkspace = makeWorkspace(id: 1, order: 0)
        let lockedWorkspace = makeWorkspace(id: 2, order: 1)
        let oldest = makeServer(id: 1, workspaceID: firstWorkspace.id, createdAt: 10)
        let middle = makeServer(id: 2, workspaceID: firstWorkspace.id, createdAt: 20)
        let newest = makeServer(id: 3, workspaceID: lockedWorkspace.id, createdAt: 30)
        let policy = ServerFreeTierPolicy(generation: .legacyThreeServers)

        #expect(
            policy.unlockedServerIDs(
                servers: [newest, oldest, middle],
                hasProAccess: false
            ) == Set([oldest.id, middle.id, newest.id])
        )
        #expect(
            policy.unlockedWorkspaceIDs(
                workspaces: [lockedWorkspace, firstWorkspace],
                hasProAccess: false
            ) == [firstWorkspace.id]
        )
    }

    @Test
    func lockedCountsSaturateAtZeroAndProUnlocksEverything() {
        let policy = ServerFreeTierPolicy(generation: .currentOneServer)
        let workspaces = [makeWorkspace(id: 1, order: 0), makeWorkspace(id: 2, order: 1)]
        let servers = [
            makeServer(id: 1, workspaceID: workspaces[0].id, createdAt: 10),
            makeServer(id: 2, workspaceID: workspaces[1].id, createdAt: 20)
        ]

        #expect(policy.lockedServerCount(serverCount: 0, hasProAccess: false) == 0)
        #expect(policy.lockedServerCount(serverCount: 2, hasProAccess: false) == 1)
        #expect(policy.lockedWorkspaceCount(workspaceCount: 2, hasProAccess: false) == 1)
        #expect(policy.unlockedServerIDs(servers: servers, hasProAccess: true) == Set(servers.map(\.id)))
        #expect(
            policy.unlockedWorkspaceIDs(workspaces: workspaces, hasProAccess: true)
                == Set(workspaces.map(\.id))
        )
    }

    private func makeWorkspace(id: Int, order: Int) -> Workspace {
        Workspace(
            id: fixedID(kind: 1, value: id),
            name: "Workspace \(id)",
            order: order,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func makeServer(id: Int, workspaceID: UUID, createdAt: TimeInterval) -> Server {
        Server(
            id: fixedID(kind: 2, value: id),
            workspaceId: workspaceID,
            name: "Server \(id)",
            host: "server\(id).example.test",
            username: "root",
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            updatedAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }

    private func fixedID(kind: Int, value: Int) -> UUID {
        UUID(uuidString: String(format: "%08d-0000-0000-0000-%012d", kind, value))!
    }
}
