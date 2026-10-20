import CryptoKit
import Foundation

nonisolated enum TeleportConfigurationError: Error, Equatable {
    case invalidProxyURL
    case invalidAccount
    case invalidConnector
    case invalidNode
}

/// Public profile metadata only. Issued credentials stay in device-only storage.
nonisolated struct TeleportProfileConfiguration: Codable, Hashable, Sendable {
    let proxyURL: String
    let account: String
    let connectorID: String?

    init(proxyURL: String, account: String, connectorID: String? = nil) throws {
        let value = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw TeleportConfigurationError.invalidProxyURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        if components.port == 443 { components.port = nil }
        guard let origin = components.url?.absoluteString else {
            throw TeleportConfigurationError.invalidProxyURL
        }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validIdentifier(account) else {
            throw TeleportConfigurationError.invalidAccount
        }
        let connector = connectorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let connector, !connector.isEmpty, !Self.validIdentifier(connector) {
            throw TeleportConfigurationError.invalidConnector
        }
        self.proxyURL = origin
        self.account = account
        self.connectorID = connector.flatMap { $0.isEmpty ? nil : $0 }
    }

    var identifier: String {
        let bytes = Data((proxyURL + "\0" + account).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case proxyURL, account, connectorID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            proxyURL: values.decode(String.self, forKey: .proxyURL),
            account: values.decode(String.self, forKey: .account),
            connectorID: values.decodeIfPresent(String.self, forKey: .connectorID)
        )
    }

    fileprivate static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

nonisolated struct TeleportServerConfiguration: Codable, Hashable, Sendable {
    let profile: TeleportProfileConfiguration
    let clusterName: String
    let nodeID: String

    init(profile: TeleportProfileConfiguration, clusterName: String, nodeID: String) throws {
        let cluster = clusterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeleportProfileConfiguration.validIdentifier(cluster),
              TeleportProfileConfiguration.validIdentifier(node) else {
            throw TeleportConfigurationError.invalidNode
        }
        self.profile = profile
        self.clusterName = cluster
        self.nodeID = node
    }

    private enum CodingKeys: String, CodingKey { case profile, clusterName, nodeID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profile: values.decode(TeleportProfileConfiguration.self, forKey: .profile),
            clusterName: values.decode(String.self, forKey: .clusterName),
            nodeID: values.decode(String.self, forKey: .nodeID)
        )
    }
}
