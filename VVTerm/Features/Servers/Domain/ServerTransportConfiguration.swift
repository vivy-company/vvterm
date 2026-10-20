import Foundation

/// Non-secret transport settings. Unknown formats remain stored but cannot connect.
nonisolated enum ServerTransportConfiguration: Codable, Hashable, Sendable {
    case teleport(TeleportServerConfiguration)
    case unsupported(type: String, version: Int, settings: Data)

    static let maximumSettingsSize = 16 * 1_024
    static let maximumEncodedSize = 64 * 1_024

    var teleport: TeleportServerConfiguration? {
        guard case .teleport(let configuration) = self else { return nil }
        return configuration
    }

    private enum CodingKeys: String, CodingKey { case type, version, settings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let version = try container.decode(Int.self, forKey: .version)
        let settings = try container.decode(Data.self, forKey: .settings)
        guard Self.valid(type: type, version: version, settings: settings) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid transport configuration or size."
            ))
        }
        if type == "teleport", version == 1 {
            self = .teleport(try JSONDecoder().decode(TeleportServerConfiguration.self, from: settings))
        } else {
            self = .unsupported(type: type, version: version, settings: settings)
        }
    }

    func encode(to encoder: Encoder) throws {
        let type: String
        let version: Int
        let settings: Data
        switch self {
        case .teleport(let configuration):
            type = "teleport"
            version = 1
            settings = try JSONEncoder().encode(configuration)
        case .unsupported(let storedType, let storedVersion, let storedSettings):
            guard storedType != "teleport" || storedVersion != 1 else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Current Teleport settings require a typed configuration."
                ))
            }
            type = storedType
            version = storedVersion
            settings = storedSettings
        }
        guard Self.valid(type: type, version: version, settings: settings) else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Invalid transport configuration or size."
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(version, forKey: .version)
        try container.encode(settings, forKey: .settings)
    }

    private static func valid(type: String, version: Int, settings: Data) -> Bool {
        !type.isEmpty && type.utf8.count <= 128 && type.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        } && version > 0 && settings.count <= maximumSettingsSize
    }
}
