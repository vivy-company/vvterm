import Foundation
import Testing
@testable import VVTerm

struct ServerFormModelTests {
    @Test
    func modelBuildsServerAndCredentialsFromOneDraft() throws {
        let workspaceID = UUID()
        let serverID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var model = ServerFormModel(
            workspaceID: workspaceID,
            defaultTmuxEnabled: false,
            defaultTmuxStartupBehavior: .askEveryTime
        )
        model.name = "Production"
        model.host = "host.example.com"
        model.port = "2222"
        model.eternalTerminalPort = "22022"
        model.username = "  "
        model.transportSelection = .cloudflare
        model.authMethod = .sshKeyWithPassphrase
        model.sshKey = "PRIVATE"
        model.sshPassphrase = "phrase"
        model.sshPublicKey = "PUBLIC"
        model.cloudflareAccessMode = .serviceToken
        model.cloudflareClientID = " client-id "
        model.cloudflareClientSecret = " client-secret "
        model.cloudflareTeamDomainOverride = " team.cloudflareaccess.com "
        model.notes = "notes"
        model.requiresBiometricUnlock = true
        model.tmuxEnabled = true
        model.tmuxStartupBehavior = .vvtermManaged

        #expect(model.isValid)

        let server = model.makeServer(
            id: serverID,
            workspaceID: workspaceID,
            createdAt: createdAt
        )
        let credentials = model.makeCredentials(serverID: serverID)

        #expect(server.id == serverID)
        #expect(server.workspaceId == workspaceID)
        #expect(server.port == 2222)
        #expect(server.eternalTerminalPort == 22022)
        #expect(server.username == "root")
        #expect(server.connectionMode == .cloudflare)
        #expect(server.cloudflareAccessMode == .serviceToken)
        #expect(server.cloudflareTeamDomainOverride == "team.cloudflareaccess.com")
        #expect(server.createdAt == createdAt)
        #expect(String(data: try #require(credentials.privateKey), encoding: .utf8) == "PRIVATE")
        #expect(credentials.passphrase == "phrase")
        #expect(String(data: try #require(credentials.publicKey), encoding: .utf8) == "PUBLIC")
        #expect(credentials.cloudflareClientID == "client-id")
        #expect(credentials.cloudflareClientSecret == "client-secret")
    }

    @Test
    func validationRejectsOutOfRangePortsAndIncompleteCredentials() {
        var model = validPasswordModel()

        model.port = "0"
        #expect(!model.isValid)
        model.port = "65536"
        #expect(!model.isValid)
        model.port = "65535"
        #expect(model.isValid)

        model.transportSelection = .eternalTerminal
        model.eternalTerminalPort = "65536"
        #expect(!model.isValid)

        model.transportSelection = .cloudflare
        model.cloudflareAccessMode = .serviceToken
        model.eternalTerminalPort = "2022"
        model.cloudflareClientID = " "
        model.cloudflareClientSecret = "secret"
        #expect(!model.isValid)
    }

    @Test
    func connectionSnapshotChangesOnlyWithConnectionFacts() {
        var model = validPasswordModel()
        let snapshot = model.connectionSnapshot

        model.name = "Renamed"
        model.notes = "New note"
        model.workspaceID = UUID()
        #expect(model.connectionSnapshot == snapshot)

        model.host = "other.example.com"
        #expect(model.connectionSnapshot != snapshot)
    }

    @Test
    func editModelRestoresServerIdentityAndCredentialValues() throws {
        let server = Server(
            id: UUID(),
            workspaceId: UUID(),
            environment: .staging,
            name: "Edit",
            host: "edit.example.com",
            port: 2200,
            username: "deploy",
            connectionMode: .standard,
            authMethod: .sshKeyWithPassphrase,
            notes: "keep",
            requiresBiometricUnlock: true,
            tmuxEnabledOverride: false,
            tmuxStartupBehaviorOverride: .askEveryTime
        )
        var model = ServerFormModel(
            server: server,
            defaultTmuxEnabled: true,
            defaultTmuxStartupBehavior: .vvtermManaged
        )
        var credentials = ServerCredentials(serverId: server.id)
        credentials.privateKey = Data("PRIVATE".utf8)
        credentials.publicKey = Data("PUBLIC".utf8)
        credentials.passphrase = "phrase"
        model.apply(credentials, for: server)

        let rebuilt = model.makeServer(
            id: server.id,
            workspaceID: try #require(model.workspaceID),
            createdAt: server.createdAt
        )

        #expect(rebuilt.id == server.id)
        #expect(rebuilt.workspaceId == server.workspaceId)
        #expect(rebuilt.environment == server.environment)
        #expect(rebuilt.name == server.name)
        #expect(rebuilt.host == server.host)
        #expect(rebuilt.username == server.username)
        #expect(rebuilt.notes == server.notes)
        #expect(model.sshKey == "PRIVATE")
        #expect(model.sshPublicKey == "PUBLIC")
        #expect(model.sshPassphrase == "phrase")
    }

    private func validPasswordModel() -> ServerFormModel {
        var model = ServerFormModel(
            defaultTmuxEnabled: true,
            defaultTmuxStartupBehavior: .vvtermManaged
        )
        model.name = "Server"
        model.host = "example.com"
        model.port = "22"
        model.password = "secret"
        return model
    }
}
