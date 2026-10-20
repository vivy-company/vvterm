import Foundation
import Testing
@testable import VVTerm

struct ServerMutationCommandRepositoryTests {
    private let repository = ServerMutationCommandRepository()
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    @Test
    func teleportConfigurationSurvivesInsertAndUpdateCommands() throws {
        let workspace = makeWorkspace()
        let configuration = try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            clusterName: "root.example.test", nodeID: "node-id"
        )
        let input = Server(
            workspaceId: workspace.id, name: "Teleport", host: configuration.nodeID,
            username: "deploy", connectionMode: .teleport,
            teleportConfiguration: configuration
        )
        let inserted = try repository.execute(
            .insertServer(input), servers: [], workspaces: [workspace], now: now
        )
        var edited = try #require(inserted.servers.first)
        #expect(edited.teleportConfiguration == configuration)
        edited.name = "Renamed"
        let updated = try repository.execute(
            .updateServer(edited), servers: inserted.servers, workspaces: [workspace], now: now
        )
        #expect(updated.servers.first?.teleportConfiguration == configuration)
        #expect(updated.servers.first?.authMethod == nil)
    }

    @Test
    func insertServerNormalizesLocalMetadata() throws {
        let workspace = makeWorkspace()
        let input = Server(
            id: fixedID(2),
            workspaceId: workspace.id,
            name: "New",
            host: "new.example.test",
            username: "root",
            iconSelection: .custom(.database),
            detectedSystemIdentity: RemoteSystemIdentity(kind: .ubuntu),
            wakeOnLANConfiguration: WakeOnLANConfiguration(
                macAddress: try WakeOnLANMACAddress("00:11:22:33:44:55")
            ),
            autoWakeOnLANEnabled: true,
            lastConnected: .distantPast,
            isFavorite: true,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let result = try repository.execute(
            .insertServer(input),
            servers: [],
            workspaces: [workspace],
            now: now
        )
        let inserted = try #require(result.servers.first)

        #expect(inserted.id == input.id)
        #expect(inserted.createdAt == now)
        #expect(inserted.updatedAt == now)
        #expect(inserted.lastConnected == nil)
        #expect(!inserted.isFavorite)
        #expect(inserted.wakeOnLANConfiguration == input.wakeOnLANConfiguration)
        #expect(inserted.autoWakeOnLANEnabled)
        #expect(inserted.iconSelection == .custom(.database))
        #expect(inserted.detectedSystemIdentity == RemoteSystemIdentity(kind: .ubuntu))
        #expect(result.effect == .serverUpsert(inserted))
    }

    @Test
    func updateServerPreservesIdentityAndUserState() throws {
        let workspace = makeWorkspace()
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let lastConnected = Date(timeIntervalSinceReferenceDate: 200)
        let input = Server(
            id: fixedID(2),
            workspaceId: workspace.id,
            name: "Edited",
            host: "edited.example.test",
            username: "root",
            iconSelection: .custom(.cloud),
            detectedSystemIdentity: RemoteSystemIdentity(kind: .debian),
            wakeOnLANConfiguration: WakeOnLANConfiguration(
                macAddress: try WakeOnLANMACAddress("AA:BB:CC:DD:EE:FF")
            ),
            autoWakeOnLANEnabled: true,
            lastConnected: lastConnected,
            isFavorite: true,
            createdAt: createdAt,
            updatedAt: .distantPast
        )

        let result = try repository.execute(
            .updateServer(input),
            servers: [input],
            workspaces: [workspace],
            now: now
        )
        let updated = try #require(result.servers.first)

        #expect(updated.id == input.id)
        #expect(updated.createdAt == createdAt)
        #expect(updated.updatedAt == now)
        #expect(updated.lastConnected == lastConnected)
        #expect(updated.isFavorite)
        #expect(updated.wakeOnLANConfiguration == input.wakeOnLANConfiguration)
        #expect(updated.autoWakeOnLANEnabled)
        #expect(updated.iconSelection == .custom(.cloud))
        #expect(updated.detectedSystemIdentity == RemoteSystemIdentity(kind: .debian))
    }

    @Test
    func staleUpdateFailsWithoutChangingCollections() {
        let workspace = makeWorkspace()
        let input = makeServer(workspaceID: workspace.id)

        #expect(throws: VVTermError.self) {
            try repository.execute(
                .updateServer(input),
                servers: [],
                workspaces: [workspace],
                now: now
            )
        }
    }

    @Test
    func workspaceCommandsPreserveOrderAndIdentity() throws {
        let existing = makeWorkspace(id: 1, order: 0)
        let insertedInput = makeWorkspace(id: 2, order: 99)
        let insertion = try repository.execute(
            .insertWorkspace(insertedInput),
            servers: [],
            workspaces: [existing],
            now: now
        )
        let inserted = try #require(insertion.workspaces.last)

        #expect(inserted.id == insertedInput.id)
        #expect(inserted.order == 1)
        #expect(inserted.createdAt == now)

        var edit = inserted
        edit.name = "Edited"
        let updateTime = now.addingTimeInterval(1)
        let update = try repository.execute(
            .updateWorkspace(edit),
            servers: [],
            workspaces: insertion.workspaces,
            now: updateTime
        )
        let updated = try #require(update.workspaces.last)

        #expect(updated.name == "Edited")
        #expect(updated.createdAt == now)
        #expect(updated.updatedAt == updateTime)
        #expect(update.effect == .workspaceUpsert(updated))
    }

    @Test
    func deleteServerReturnsTheDeletedIdentity() throws {
        let workspace = makeWorkspace()
        let server = makeServer(workspaceID: workspace.id)

        let result = try repository.execute(
            .deleteServer(server.id),
            servers: [server],
            workspaces: [workspace],
            now: now
        )

        #expect(result.servers.isEmpty)
        #expect(result.effect == .serverDelete(server))
    }

    private func makeWorkspace(id: Int = 1, order: Int = 0) -> Workspace {
        Workspace(
            id: fixedID(id),
            name: "Workspace",
            order: order,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID) -> Server {
        Server(
            id: fixedID(2),
            workspaceId: workspaceID,
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
