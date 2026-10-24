import Foundation
import Testing
@testable import VVTerm

struct TeleportServerConfigurationTests {
    @Test
    func equivalentOriginsShareOneCredentialProfileAcrossNodes() throws {
        let first = try TeleportProfileConfiguration(
            proxyURL: " HTTPS://PROXY.EXAMPLE.TEST:443/ ", account: " alice "
        )
        let second = try TeleportProfileConfiguration(
            proxyURL: "https://proxy.example.test", account: "alice"
        )
        #expect(first.proxyURL == "https://proxy.example.test")
        #expect(first.account == "alice")
        #expect(first.identifier == second.identifier)
        #expect(first.identifier.count == 64)
        let otherAccount = try TeleportProfileConfiguration(
            proxyURL: first.proxyURL, account: "bob"
        )
        let otherPort = try TeleportProfileConfiguration(
            proxyURL: "https://proxy.example.test:8443", account: "alice"
        )
        #expect(first.identifier != otherAccount.identifier)
        #expect(first.identifier != otherPort.identifier)
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(first)
        ) as? [String: Any])
        #expect(Set(object.keys) == ["proxyURL", "account"])
    }

    @Test(arguments: [
        "proxy.example.test", "proxy.example.test:8443",
        "http://proxy.example.test", "https://alice@proxy.example.test",
        "https://proxy.example.test/path", "https://proxy.example.test?query",
        "https://proxy.example.test#fragment", "https://proxy.example.test:0",
        "https://proxy.example.test:65536", "https:///", ""
    ])
    func invalidProxyOriginsAreRejected(origin: String) {
        #expect(throws: TeleportConfigurationError.self) {
            try TeleportProfileConfiguration(proxyURL: origin, account: "alice")
        }
    }

    @Test
    func decodingCannotBypassProfileOrNodeValidation() throws {
        let invalidProfile = Data(#"{"proxyURL":"http://proxy.example.test","account":"alice"}"#.utf8)
        #expect(throws: TeleportConfigurationError.self) {
            try JSONDecoder().decode(TeleportProfileConfiguration.self, from: invalidProfile)
        }
        #expect(throws: TeleportConfigurationError.self) {
            try TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice\0bob")
        }
        let configuration = try makeConfiguration()
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(configuration)
        ) as? [String: Any])
        object["nodeID"] = "\n"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: TeleportConfigurationError.self) {
            try JSONDecoder().decode(TeleportServerConfiguration.self, from: data)
        }
    }

    @Test
    func teleportRoundTripStoresOnlyProfileAndNodeMetadataWithoutOrdinaryAuthentication() throws {
        let configuration = try makeConfiguration()
        let server = Server(
            workspaceId: UUID(), name: "Node", host: configuration.nodeID,
            username: "deploy", connectionMode: .teleport, authMethod: .sshKey,
            teleportConfiguration: configuration
        )
        let data = try JSONEncoder().encode(server)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["authMethod"] == nil)
        #expect(server.authMethod == nil)
        #expect(try JSONDecoder().decode(Server.self, from: data) == server)
        // Old or stale ordinary-auth metadata must not change the Teleport path.
        object["authMethod"] = "password"
        let staleData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Server.self, from: staleData)
        #expect(decoded.authMethod == nil)
        #expect(decoded.teleportConfiguration == configuration)
    }

    @Test
    func oldSSHRecordsKeepTheirAuthenticationAndDoNotAcquireTeleportMetadata() throws {
        let server = Server(
            workspaceId: UUID(), name: "SSH", host: "host.example.test",
            username: "deploy", authMethod: .sshKey
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(server)
        ) as? [String: Any])
        object.removeValue(forKey: "connectionMode")
        object.removeValue(forKey: "transportConfiguration")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.connectionMode == .standard)
        #expect(decoded.authMethod == .sshKey)
        #expect(decoded.teleportConfiguration == nil)
        object.removeValue(forKey: "authMethod")
        let legacyDefault = try JSONDecoder().decode(
            Server.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacyDefault.authMethod == .password)
    }

    @Test
    func teleportRequiresConfigurationAndChangingTransportClearsItsMetadata() throws {
        var server = Server(
            workspaceId: UUID(), name: "Node", host: "node-id",
            username: "deploy", connectionMode: .teleport,
            teleportConfiguration: try makeConfiguration()
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(server)
        ) as? [String: Any])
        object.removeValue(forKey: "transportConfiguration")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Server.self, from: JSONSerialization.data(withJSONObject: object))
        }
        server.authMethod = .password
        #expect(server.authMethod == nil)
        server.connectionMode = .standard
        #expect(server.teleportConfiguration == nil)
        #expect(server.authMethod == .password)
    }

    private func makeConfiguration() throws -> TeleportServerConfiguration {
        try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            clusterName: "root.example.test", nodeID: "node-id"
        )
    }
}
