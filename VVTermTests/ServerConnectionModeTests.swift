import Foundation
import Testing
@testable import VVTerm

struct ServerConnectionModeTests {
    private func makeServer(
        connectionMode: SSHConnectionMode = .standard,
        authMethod: AuthMethod = .password
    ) -> Server {
        Server(
            id: UUID(),
            workspaceId: UUID(),
            environment: .production,
            name: "Test Server",
            host: "example.com",
            port: 22,
            username: "root",
            connectionMode: connectionMode,
            authMethod: authMethod,
            tags: ["test"],
            notes: "note",
            lastConnected: nil,
            isFavorite: false,
            tmuxEnabledOverride: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func mutateJSON(_ server: Server, mutate: (inout [String: Any]) -> Void) throws -> Data {
        let encoded = try JSONEncoder().encode(server)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test
    func decodeWithoutConnectionModeDefaultsToStandard() throws {
        let server = makeServer(connectionMode: .tailscale, authMethod: .password)
        let data = try mutateJSON(server) { object in
            object.removeValue(forKey: "connectionMode")
        }

        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.connectionMode == .standard)
    }

    @Test
    func decodeWithUnknownConnectionModeDefaultsToStandard() throws {
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let data = try mutateJSON(server) { object in
            object["connectionMode"] = "future-mode"
        }

        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.connectionMode == .standard)
    }

    @Test
    func tailscaleSelectionMapsToTailscaleModeAndEmptyCredentials() {
        let server = makeServer(connectionMode: .tailscale, authMethod: .sshKeyWithPassphrase)
        #expect(ServerAuthSelection(server: server) == .tailscale)
        #expect(ServerAuthSelection.tailscale.connectionMode == .tailscale)
        #expect(ServerAuthSelection.tailscale.authMethod == .password)

        let credentials = ServerFormCredentialBuilder.build(
            serverId: UUID(),
            authSelection: .tailscale,
            password: "secret",
            sshKey: "PRIVATE",
            sshPassphrase: "phrase",
            sshPublicKey: "PUBLIC"
        )

        #expect(credentials.password == nil)
        #expect(credentials.privateKey == nil)
        #expect(credentials.passphrase == nil)
        #expect(credentials.publicKey == nil)
    }

    @Test
    func standardSelectionsPreserveCredentials() {
        let passwordCredentials = ServerFormCredentialBuilder.build(
            serverId: UUID(),
            authSelection: .password,
            password: "secret",
            sshKey: "",
            sshPassphrase: "",
            sshPublicKey: ""
        )
        #expect(passwordCredentials.password == "secret")

        let keyCredentials = ServerFormCredentialBuilder.build(
            serverId: UUID(),
            authSelection: .sshKeyWithPassphrase,
            password: "",
            sshKey: "PRIVATE_KEY",
            sshPassphrase: "phrase",
            sshPublicKey: "PUBLIC_KEY"
        )
        #expect(String(data: keyCredentials.privateKey ?? Data(), encoding: .utf8) == "PRIVATE_KEY")
        #expect(keyCredentials.passphrase == "phrase")
        #expect(String(data: keyCredentials.publicKey ?? Data(), encoding: .utf8) == "PUBLIC_KEY")
    }
}
