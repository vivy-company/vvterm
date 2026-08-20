import Foundation
import Testing
@testable import VVTerm

struct ServerConnectionModeTests {
    private func makeCredentials(
        serverId: UUID,
        transportSelection: ServerTransportSelection,
        authMethod: AuthMethod,
        password: String,
        sshKey: String,
        sshPassphrase: String,
        sshPublicKey: String,
        cloudflareAccessMode: CloudflareAccessMode?,
        cloudflareClientID: String,
        cloudflareClientSecret: String
    ) -> ServerCredentials {
        var form = ServerFormModel(
            defaultTmuxEnabled: true,
            defaultTmuxStartupBehavior: .vvtermManaged
        )
        form.transportSelection = transportSelection
        form.authMethod = authMethod
        form.password = password
        form.sshKey = sshKey
        form.sshPassphrase = sshPassphrase
        form.sshPublicKey = sshPublicKey
        form.cloudflareAccessMode = cloudflareAccessMode ?? .oauth
        form.cloudflareClientID = cloudflareClientID
        form.cloudflareClientSecret = cloudflareClientSecret
        return form.makeCredentials(serverID: serverId)
    }

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
    func decodeWithoutBiometricFlagDefaultsToFalse() throws {
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let data = try mutateJSON(server) { object in
            object.removeValue(forKey: "requiresBiometricUnlock")
        }

        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.requiresBiometricUnlock == false)
    }

    @Test
    func encodeDecodePreservesBiometricFlag() throws {
        var server = makeServer(connectionMode: .standard, authMethod: .password)
        server.requiresBiometricUnlock = true

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.requiresBiometricUnlock == true)
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
    func decodeMoshConnectionMode() throws {
        let server = makeServer(connectionMode: .mosh, authMethod: .sshKey)
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.connectionMode == .mosh)
    }

    @Test
    func eternalTerminalRoundTripPreservesModeAndPort() throws {
        var server = makeServer(connectionMode: .eternalTerminal, authMethod: .sshKey)
        server.eternalTerminalPort = 22022

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)

        #expect(decoded.connectionMode == .eternalTerminal)
        #expect(decoded.eternalTerminalPort == 22022)
        #expect(ServerTransportSelection(server: decoded) == .eternalTerminal)
        #expect(ServerTransportSelection.eternalTerminal.connectionMode == .eternalTerminal)
    }

    @Test
    func decodeWithoutEternalTerminalPortDefaultsTo2022() throws {
        let server = makeServer(connectionMode: .eternalTerminal, authMethod: .password)
        let data = try mutateJSON(server) { object in
            object.removeValue(forKey: "eternalTerminalPort")
        }

        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.eternalTerminalPort == 2022)
    }

    @Test
    func invalidEternalTerminalPortDefaultsTo2022() throws {
        let server = makeServer(connectionMode: .eternalTerminal, authMethod: .password)
        let data = try mutateJSON(server) { object in
            object["eternalTerminalPort"] = 100_000
        }

        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.eternalTerminalPort == 2022)
    }

    @Test
    func decodeCloudflareConnectionMode() throws {
        let server = makeServer(connectionMode: .cloudflare, authMethod: .password)
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.connectionMode == .cloudflare)
    }

    @Test
    func tailscaleSelectionMapsToTailscaleModeAndEmptyCredentials() {
        let server = makeServer(connectionMode: .tailscale, authMethod: .sshKeyWithPassphrase)
        #expect(ServerTransportSelection(server: server) == .tailscale)
        #expect(ServerTransportSelection.tailscale.connectionMode == .tailscale)

        let credentials = makeCredentials(
            serverId: UUID(),
            transportSelection: .tailscale,
            authMethod: .password,
            password: "secret",
            sshKey: "PRIVATE",
            sshPassphrase: "phrase",
            sshPublicKey: "PUBLIC",
            cloudflareAccessMode: nil,
            cloudflareClientID: "",
            cloudflareClientSecret: ""
        )

        #expect(credentials.password == nil)
        #expect(credentials.privateKey == nil)
        #expect(credentials.passphrase == nil)
        #expect(credentials.publicKey == nil)
    }

    @Test
    func moshPasswordSelectionPreservesPasswordCredentials() {
        let passwordCredentials = makeCredentials(
            serverId: UUID(),
            transportSelection: .mosh,
            authMethod: .password,
            password: "secret",
            sshKey: "",
            sshPassphrase: "",
            sshPublicKey: "",
            cloudflareAccessMode: nil,
            cloudflareClientID: "",
            cloudflareClientSecret: ""
        )
        #expect(passwordCredentials.password == "secret")
        #expect(passwordCredentials.privateKey == nil)
    }

    @Test
    func moshKeySelectionPreservesKeyCredentials() {
        let keyCredentials = makeCredentials(
            serverId: UUID(),
            transportSelection: .mosh,
            authMethod: .sshKeyWithPassphrase,
            password: "",
            sshKey: "PRIVATE_KEY",
            sshPassphrase: "phrase",
            sshPublicKey: "PUBLIC_KEY",
            cloudflareAccessMode: nil,
            cloudflareClientID: "",
            cloudflareClientSecret: ""
        )
        #expect(String(data: keyCredentials.privateKey ?? Data(), encoding: .utf8) == "PRIVATE_KEY")
        #expect(keyCredentials.passphrase == "phrase")
        #expect(String(data: keyCredentials.publicKey ?? Data(), encoding: .utf8) == "PUBLIC_KEY")
    }

    @Test
    func eternalTerminalSelectionPreservesSSHCredentials() {
        let credentials = makeCredentials(
            serverId: UUID(),
            transportSelection: .eternalTerminal,
            authMethod: .password,
            password: "secret",
            sshKey: "",
            sshPassphrase: "",
            sshPublicKey: "",
            cloudflareAccessMode: nil,
            cloudflareClientID: "",
            cloudflareClientSecret: ""
        )

        #expect(credentials.password == "secret")
        #expect(credentials.privateKey == nil)
    }

    @Test
    func cloudflareServiceTokenPreservesSSHAndAccessCredentials() {
        let credentials = makeCredentials(
            serverId: UUID(),
            transportSelection: .cloudflare,
            authMethod: .password,
            password: "ssh-password",
            sshKey: "",
            sshPassphrase: "",
            sshPublicKey: "",
            cloudflareAccessMode: .serviceToken,
            cloudflareClientID: "cf-id",
            cloudflareClientSecret: "cf-secret"
        )

        #expect(credentials.password == "ssh-password")
        #expect(credentials.cloudflareClientID == "cf-id")
        #expect(credentials.cloudflareClientSecret == "cf-secret")
    }
}
