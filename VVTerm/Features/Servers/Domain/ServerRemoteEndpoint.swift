import Foundation

nonisolated struct ServerRemoteEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let sshPort: Int?
    let connectionMode: SSHConnectionMode
    let teleportConfiguration: TeleportServerConfiguration?
    let eternalTerminalPort: Int?
    let cloudflareTeamDomainOverride: String?
    let cloudflareAppDomainOverride: String?

    init(server: Server) {
        self.init(
            host: server.host,
            sshPort: server.port,
            connectionMode: server.connectionMode,
            eternalTerminalPort: server.eternalTerminalPort,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            teleportConfiguration: server.teleportConfiguration
        )
    }

    init(
        host: String,
        sshPort: Int?,
        connectionMode: SSHConnectionMode,
        eternalTerminalPort: Int?,
        cloudflareTeamDomainOverride: String?,
        cloudflareAppDomainOverride: String?,
        teleportConfiguration: TeleportServerConfiguration? = nil
    ) {
        self.host = Self.normalized(host) ?? ""
        self.sshPort = sshPort
        self.connectionMode = connectionMode
        self.teleportConfiguration = connectionMode == .teleport ? teleportConfiguration : nil
        self.eternalTerminalPort = connectionMode == .eternalTerminal
            ? eternalTerminalPort
            : nil
        self.cloudflareTeamDomainOverride = connectionMode == .cloudflare
            ? Self.normalized(cloudflareTeamDomainOverride)
            : nil
        self.cloudflareAppDomainOverride = connectionMode == .cloudflare
            ? Self.normalized(cloudflareAppDomainOverride)
            : nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
