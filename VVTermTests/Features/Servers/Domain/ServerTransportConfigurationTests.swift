import Foundation
import Testing
@testable import VVTerm

struct ServerTransportConfigurationTests {
    @Test
    func savedTeleportSettingsUseTheGenericFormatOnTheNextWrite() throws {
        let configuration = try teleportConfiguration()
        let object = try legacyServerObject(configuration: configuration)
        let decoded = try JSONDecoder().decode(
            Server.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.teleportConfiguration == configuration)
        #expect(decoded.isTransportSupported)
        let saved = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        ) as? [String: Any])
        #expect(saved["transportConfiguration"] != nil)
        #expect(saved["teleportConfiguration"] == nil)
    }

    @Test(arguments: [false, true])
    func presentInvalidGenericSettingsNeverUseLegacySettings(isNull: Bool) throws {
        var object = try legacyServerObject(configuration: teleportConfiguration())
        if isNull {
            object["transportConfiguration"] = NSNull()
        } else {
            object["transportConfiguration"] = ["invalid": true]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Server.self, from: data) }
    }

    @Test
    func oversizedLegacySettingsAreRejected() throws {
        var object = try legacyServerObject(configuration: teleportConfiguration())
        var legacy = try #require(object["teleportConfiguration"] as? [String: Any])
        legacy["nodeID"] = String(repeating: "x", count: ServerTransportConfiguration.maximumSettingsSize)
        object["teleportConfiguration"] = legacy
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Server.self, from: data) }
    }

    @Test
    func teleportUsesOneVersionedPayloadAndKeepsTheTypedAccessor() throws {
        let configuration = try teleportConfiguration()
        let server = Server(
            workspaceId: UUID(), name: "Teleport", host: configuration.nodeID,
            username: "deploy", connectionMode: .teleport,
            teleportConfiguration: configuration
        )
        let data = try JSONEncoder().encode(server)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["transportConfiguration"] as? [String: Any])
        #expect(payload["type"] as? String == "teleport")
        #expect(payload["version"] as? Int == 1)
        #expect(object["teleportConfiguration"] == nil)
        #expect(object["authMethod"] == nil)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded == server)
        #expect(decoded.teleportConfiguration == configuration)
        #expect(decoded.isTransportSupported)
    }

    @Test(arguments: [("other-provider", 1), ("teleport", 2)])
    func unknownPayloadsSurviveWithoutBecomingUsable(type: String, version: Int) throws {
        let payload = ServerTransportConfiguration.unsupported(
            type: type, version: version, settings: Data([0, 1, 255])
        )
        let server = Server(
            workspaceId: UUID(), name: "Future", host: "node-id", username: "deploy",
            connectionMode: .teleport, transportConfiguration: payload
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(server)
        ) as? [String: Any])
        object["teleportConfiguration"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(teleportConfiguration())
        )
        let decoded = try JSONDecoder().decode(
            Server.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.transportConfiguration == payload)
        #expect(decoded.teleportConfiguration == nil)
        #expect(!decoded.isTransportSupported)
    }

    @Test
    func unknownSettingsCannotUseAnOrdinarySSHMode() {
        let server = Server(
            workspaceId: UUID(), name: "Future", host: "server.example.test", username: "deploy",
            transportConfiguration: .unsupported(type: "future", version: 1, settings: Data())
        )
        #expect(!server.isTransportSupported)
    }

    @Test
    func changingTransportClearsThePayloadAndRestoresSSHAuthentication() throws {
        var server = Server(
            workspaceId: UUID(), name: "Teleport", host: "node-id", username: "deploy",
            connectionMode: .teleport, teleportConfiguration: try teleportConfiguration()
        )
        server.connectionMode = .standard
        #expect(server.transportConfiguration == nil)
        #expect(server.authMethod == .password)
        #expect(server.isTransportSupported)
    }

    @Test
    func oversizedPayloadsAreRejectedOnEncodeAndDecode() throws {
        let payload = ServerTransportConfiguration.unsupported(
            type: "future", version: 1,
            settings: Data(repeating: 0, count: ServerTransportConfiguration.maximumSettingsSize + 1)
        )
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(payload) }
        let object: [String: Any] = [
            "type": "future", "version": 1,
            "settings": Data(repeating: 0, count: ServerTransportConfiguration.maximumSettingsSize + 1)
                .base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ServerTransportConfiguration.self, from: data)
        }
    }

    @Test
    func malformedCurrentSettingsAreRejectedInsteadOfBeingRetainedAsFutureData() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "teleport", "version": 1, "settings": Data("{}".utf8).base64EncodedString()
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ServerTransportConfiguration.self, from: data)
        }
    }

    @Test(arguments: [0, -1])
    func invalidVersionsAreRejected(version: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "future", "version": version, "settings": ""
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ServerTransportConfiguration.self, from: data)
        }
    }

    private func teleportConfiguration() throws -> TeleportServerConfiguration {
        try TeleportServerConfiguration(
            profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            clusterName: "root.example.test", nodeID: "node-id"
        )
    }

    private func legacyServerObject(configuration: TeleportServerConfiguration) throws -> [String: Any] {
        let server = Server(
            workspaceId: UUID(), name: "Saved Teleport", host: configuration.nodeID,
            username: "deploy", connectionMode: .teleport, teleportConfiguration: configuration
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(server)
        ) as? [String: Any])
        object.removeValue(forKey: "transportConfiguration")
        object["teleportConfiguration"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(configuration)
        )
        return object
    }
}
