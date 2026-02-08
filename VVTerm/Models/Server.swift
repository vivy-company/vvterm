import Foundation

// MARK: - Server Model (CloudKit synced)

struct Server: Identifiable, Codable, Hashable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
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
    /// Override for tmux persistence (nil = use global default)
    var tmuxEnabledOverride: Bool?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        environment: ServerEnvironment = .production,
        name: String,
        host: String,
        port: Int = 22,
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
        tmuxEnabledOverride: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.environment = environment
        self.name = name
        self.host = host
        self.port = port
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
        self.tmuxEnabledOverride = tmuxEnabledOverride
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
        case tmuxEnabledOverride
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
        tmuxEnabledOverride = try container.decodeIfPresent(Bool.self, forKey: .tmuxEnabledOverride)
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
        try container.encodeIfPresent(tmuxEnabledOverride, forKey: .tmuxEnabledOverride)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

enum SSHConnectionMode: String, Codable, CaseIterable, Identifiable {
    case standard
    case tailscale
    case mosh
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

enum CloudflareAccessMode: String, Codable, CaseIterable, Identifiable {
    case oauth
    case serviceToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oauth:
            return String(localized: "OAuth")
        case .serviceToken:
            return String(localized: "Service Token")
        }
    }
}

// MARK: - Authentication Method

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case sshKey
    case sshKeyWithPassphrase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .sshKey: return String(localized: "SSH Key")
        case .sshKeyWithPassphrase: return String(localized: "SSH Key + Passphrase")
        }
    }

    var icon: String {
        switch self {
        case .password: return "key.fill"
        case .sshKey: return "lock.doc.fill"
        case .sshKeyWithPassphrase: return "lock.shield.fill"
        }
    }
}

// MARK: - Server Credentials (for authentication)

struct ServerCredentials {
    let serverId: UUID
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
    var keyType: SSHKeyType?
    var publicKey: String?

    init(
        id: UUID = UUID(),
        name: String,
        hasPassphrase: Bool = false,
        createdAt: Date = Date(),
        keyType: SSHKeyType? = nil,
        publicKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
        self.keyType = keyType
        self.publicKey = publicKey
    }
}
