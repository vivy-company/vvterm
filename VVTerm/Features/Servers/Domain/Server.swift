import Foundation

// MARK: - Server Model

nonisolated struct Server: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
    /// TCP port exposed by etserver. SSH still uses `port` for bootstrap.
    var eternalTerminalPort: Int
    var username: String
    var connectionMode: SSHConnectionMode
    var authMethod: AuthMethod
    var cloudflareAccessMode: CloudflareAccessMode?
    var cloudflareTeamDomainOverride: String?
    var cloudflareAppDomainOverride: String?
    var tags: [String]
    var notes: String?
    var lastConnected: Date?
    var isFavorite: Bool
    var requiresBiometricUnlock: Bool
    /// Override for tmux persistence (nil = use global default)
    var tmuxEnabledOverride: Bool?
    /// Override for tmux startup behavior (nil = use global default)
    var tmuxStartupBehaviorOverride: TmuxStartupBehavior?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        environment: ServerEnvironment = .production,
        name: String,
        host: String,
        port: Int = 22,
        eternalTerminalPort: Int = 2022,
        username: String,
        connectionMode: SSHConnectionMode = .standard,
        authMethod: AuthMethod = .password,
        cloudflareAccessMode: CloudflareAccessMode? = nil,
        cloudflareTeamDomainOverride: String? = nil,
        cloudflareAppDomainOverride: String? = nil,
        tags: [String] = [],
        notes: String? = nil,
        lastConnected: Date? = nil,
        isFavorite: Bool = false,
        requiresBiometricUnlock: Bool = false,
        tmuxEnabledOverride: Bool? = nil,
        tmuxStartupBehaviorOverride: TmuxStartupBehavior? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.environment = environment
        self.name = name
        self.host = host
        self.port = port
        self.eternalTerminalPort = (1...65535).contains(eternalTerminalPort)
            ? eternalTerminalPort
            : 2022
        self.username = username
        self.connectionMode = connectionMode
        self.authMethod = authMethod
        self.cloudflareAccessMode = cloudflareAccessMode
        self.cloudflareTeamDomainOverride = cloudflareTeamDomainOverride
        self.cloudflareAppDomainOverride = cloudflareAppDomainOverride
        self.tags = tags
        self.notes = notes
        self.lastConnected = lastConnected
        self.isFavorite = isFavorite
        self.requiresBiometricUnlock = requiresBiometricUnlock
        self.tmuxEnabledOverride = tmuxEnabledOverride
        self.tmuxStartupBehaviorOverride = tmuxStartupBehaviorOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayAddress: String {
        if port == 22 {
            return "\(username)@\(host)"
        }
        return "\(username)@\(host):\(port)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceId
        case environment
        case name
        case host
        case port
        case eternalTerminalPort
        case username
        case connectionMode
        case authMethod
        case cloudflareAccessMode
        case cloudflareTeamDomainOverride
        case cloudflareAppDomainOverride
        case tags
        case notes
        case lastConnected
        case isFavorite
        case requiresBiometricUnlock
        case tmuxEnabledOverride
        case tmuxStartupBehaviorOverride
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceId = try container.decode(UUID.self, forKey: .workspaceId)
        environment = try container.decodeIfPresent(ServerEnvironment.self, forKey: .environment) ?? .production
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        let decodedETPort = try container.decodeIfPresent(Int.self, forKey: .eternalTerminalPort) ?? 2022
        eternalTerminalPort = (1...65535).contains(decodedETPort) ? decodedETPort : 2022
        username = try container.decode(String.self, forKey: .username)
        connectionMode = try container.decodeIfPresent(SSHConnectionMode.self, forKey: .connectionMode) ?? .standard
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        if let rawCloudflareMode = try container.decodeIfPresent(String.self, forKey: .cloudflareAccessMode) {
            cloudflareAccessMode = CloudflareAccessMode(rawValue: rawCloudflareMode)
        } else {
            cloudflareAccessMode = nil
        }
        cloudflareTeamDomainOverride = try container.decodeIfPresent(String.self, forKey: .cloudflareTeamDomainOverride)
        cloudflareAppDomainOverride = try container.decodeIfPresent(String.self, forKey: .cloudflareAppDomainOverride)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        requiresBiometricUnlock = try container.decodeIfPresent(Bool.self, forKey: .requiresBiometricUnlock) ?? false
        tmuxEnabledOverride = try container.decodeIfPresent(Bool.self, forKey: .tmuxEnabledOverride)
        if let raw = try container.decodeIfPresent(String.self, forKey: .tmuxStartupBehaviorOverride) {
            tmuxStartupBehaviorOverride = TmuxStartupBehavior(rawValue: raw)
        } else {
            tmuxStartupBehaviorOverride = nil
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encode(environment, forKey: .environment)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(eternalTerminalPort, forKey: .eternalTerminalPort)
        try container.encode(username, forKey: .username)
        try container.encode(connectionMode, forKey: .connectionMode)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(cloudflareAccessMode, forKey: .cloudflareAccessMode)
        try container.encodeIfPresent(cloudflareTeamDomainOverride, forKey: .cloudflareTeamDomainOverride)
        try container.encodeIfPresent(cloudflareAppDomainOverride, forKey: .cloudflareAppDomainOverride)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(requiresBiometricUnlock, forKey: .requiresBiometricUnlock)
        try container.encodeIfPresent(tmuxEnabledOverride, forKey: .tmuxEnabledOverride)
        try container.encodeIfPresent(tmuxStartupBehaviorOverride, forKey: .tmuxStartupBehaviorOverride)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

nonisolated enum SSHConnectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case tailscale
    case mosh
    case eternalTerminal
    case cloudflare

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.standard.rawValue
        self = Self(rawValue: rawValue) ?? .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum CloudflareAccessMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case oauth
    case serviceToken

    var id: String { rawValue }

}

// MARK: - Authentication Method

nonisolated enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case sshKey
    case sshKeyWithPassphrase

    var id: String { rawValue }

}

// MARK: - Server Credentials (for authentication)

nonisolated struct ServerCredentials: Sendable {
    let serverId: UUID
    var credentialBinding: ServerCredentialBinding?
    var password: String?
    var privateKey: Data?
    var publicKey: Data?
    var passphrase: String?
    var cloudflareClientID: String?
    var cloudflareClientSecret: String?

    var sshKey: Data? {
        get { privateKey }
        set { privateKey = newValue }
    }

    var sshPassphrase: String? {
        get { passphrase }
        set { passphrase = newValue }
    }
}

// MARK: - Stored SSH Key Entry (reusable keys in Keychain)

struct SSHKeyEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hasPassphrase: Bool
    var createdAt: Date
    var updatedAt: Date
    var keyType: SSHKeyType?
    var publicKey: String?

    init(
        id: UUID = UUID(),
        name: String,
        hasPassphrase: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        keyType: SSHKeyType? = nil,
        publicKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.keyType = keyType
        self.publicKey = publicKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case hasPassphrase
        case createdAt
        case updatedAt
        case keyType
        case publicKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hasPassphrase = try container.decode(Bool.self, forKey: .hasPassphrase)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        keyType = try container.decodeIfPresent(SSHKeyType.self, forKey: .keyType)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
    }
}
