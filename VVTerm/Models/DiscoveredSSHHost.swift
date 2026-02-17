import Foundation

enum DiscoverySource: String, CaseIterable, Codable, Hashable, Sendable {
    case bonjour
    case portScan

    var label: String {
        switch self {
        case .bonjour:
            return String(localized: "Bonjour")
        case .portScan:
            return String(localized: "Port Scan")
        }
    }
}

struct DiscoveredSSHHost: Identifiable, Hashable, Sendable {
    var displayName: String
    var host: String
    var port: Int
    var sources: Set<DiscoverySource>
    var lastSeenAt: Date
    var latencyMs: Int?

    var id: String {
        "\(host):\(port)"
    }

    init(
        displayName: String,
        host: String,
        port: Int = 22,
        sources: Set<DiscoverySource>,
        lastSeenAt: Date = Date(),
        latencyMs: Int? = nil
    ) {
        self.displayName = displayName.isEmpty ? host : displayName
        self.host = host
        self.port = port
        self.sources = sources
        self.lastSeenAt = lastSeenAt
        self.latencyMs = latencyMs
    }

    mutating func merge(with newer: DiscoveredSSHHost) {
        if !newer.displayName.isEmpty && newer.displayName != newer.host {
            displayName = newer.displayName
        }
        sources.formUnion(newer.sources)
        lastSeenAt = max(lastSeenAt, newer.lastSeenAt)
        if let newerLatency = newer.latencyMs {
            latencyMs = newerLatency
        }
    }
}

struct ServerFormPrefill: Equatable, Sendable {
    var name: String
    var host: String
    var port: Int
    var username: String?

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
    }

    init(discoveredHost: DiscoveredSSHHost) {
        self.name = discoveredHost.displayName
        self.host = discoveredHost.host
        self.port = discoveredHost.port
        self.username = nil
    }
}
