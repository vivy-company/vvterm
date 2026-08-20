import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerCredentialBindingTests {
    @Test
    func metadataOnlyChangesKeepCredentialBinding() {
        let original = makeServer()
        var updated = original
        updated.name = "Renamed"
        updated.notes = "Metadata only"
        updated.tags = ["new-tag"]
        updated.workspaceId = UUID()
        updated.environment = .development

        #expect(ServerCredentialBinding(server: original) == ServerCredentialBinding(server: updated))
    }

    @Test(arguments: EndpointChange.allCases)
    func endpointChangesInvalidateAnInMemoryCredentialBinding(change: EndpointChange) {
        let original = makeServer(connectionMode: .cloudflare)
        var updated = original
        change.apply(to: &updated)
        let credentials = ServerCredentials(
            serverId: original.id,
            credentialBinding: ServerCredentialBinding(server: original),
            password: "secret"
        )

        #expect(!credentials.isAuthorized(for: updated))
    }

    @Test
    func equivalentNetworkNamesKeepCredentialBinding() {
        let original = makeServer(host: " EXAMPLE.COM. ", connectionMode: .cloudflare)
        var updated = original
        updated.host = "example.com"
        updated.cloudflareTeamDomainOverride = " TEAM.EXAMPLE.COM. "

        var normalizedOriginal = original
        normalizedOriginal.cloudflareTeamDomainOverride = "team.example.com"

        #expect(
            ServerCredentialBinding(server: normalizedOriginal)
                == ServerCredentialBinding(server: updated)
        )
    }

    @Test
    func inMemoryCredentialsAuthorizeOnlyTheirBoundEndpoint() {
        let original = makeServer()
        let credentials = ServerCredentials(
            serverId: original.id,
            credentialBinding: ServerCredentialBinding(server: original),
            password: "secret"
        )

        #expect(credentials.isAuthorized(for: original))

        var changed = original
        changed.host = "other.example.com"

        #expect(!credentials.isAuthorized(for: changed))
    }

    @Test
    func unboundInMemoryCredentialsAreRejected() {
        let server = makeServer()
        let credentials = ServerCredentials(serverId: server.id, password: "secret")

        #expect(!credentials.isAuthorized(for: server))
    }

    enum EndpointChange: CaseIterable {
        case host
        case port
        case eternalTerminalPort
        case username
        case connectionMode
        case authMethod
        case cloudflareAccessMode
        case cloudflareTeamDomain
        case cloudflareAppDomain

        func apply(to server: inout Server) {
            switch self {
            case .host:
                server.host = "other.example.com"
            case .port:
                server.port = 2222
            case .eternalTerminalPort:
                server.connectionMode = .eternalTerminal
                server.eternalTerminalPort = 2023
            case .username:
                server.username = "other-user"
            case .connectionMode:
                server.connectionMode = .standard
            case .authMethod:
                server.authMethod = .sshKey
            case .cloudflareAccessMode:
                server.cloudflareAccessMode = .serviceToken
            case .cloudflareTeamDomain:
                server.cloudflareTeamDomainOverride = "other.cloudflareaccess.com"
            case .cloudflareAppDomain:
                server.cloudflareAppDomainOverride = "other.example.com"
            }
        }
    }

    private func makeServer(
        host: String = "example.com",
        connectionMode: SSHConnectionMode = .eternalTerminal
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: host,
            port: 22,
            eternalTerminalPort: 2022,
            username: "root",
            connectionMode: connectionMode,
            authMethod: .password,
            cloudflareAccessMode: connectionMode == .cloudflare ? .oauth : nil,
            cloudflareTeamDomainOverride: connectionMode == .cloudflare
                ? "team.cloudflareaccess.com"
                : nil,
            cloudflareAppDomainOverride: connectionMode == .cloudflare
                ? "app.example.com"
                : nil
        )
    }
}
