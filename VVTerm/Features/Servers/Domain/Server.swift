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
    var connectionMode: SSHConnectionMode {
        didSet {
            guard connectionMode != oldValue else { return }
            transportConfiguration = nil
            authMethod = connectionMode.usesSSHAuthentication ? (authMethod ?? .password) : nil
        }
    }
    var authMethod: AuthMethod? {
        didSet {
            if !connectionMode.usesSSHAuthentication { authMethod = nil }
        }
    }
    var transportConfiguration: ServerTransportConfiguration?
    var teleportConfiguration: TeleportServerConfiguration? {
        get { connectionMode == .teleport ? transportConfiguration?.teleport : nil }
        set {
            transportConfiguration = connectionMode == .teleport ? newValue.map { .teleport($0) } : nil
        }
    }
    var isTransportSupported: Bool {
        switch (connectionMode, transportConfiguration) {
        case (.teleport, .teleport): true
        case (.standard, nil), (.tailscale, nil), (.mosh, nil), (.eternalTerminal, nil), (.cloudflare, nil): true
        default: false
        }
    }
    var iconSelection: ServerIconSelection
    var detectedSystemIdentity: RemoteSystemIdentity?
    var cloudflareAccessMode: CloudflareAccessMode?
    var cloudflareTeamDomainOverride: String?
    var cloudflareAppDomainOverride: String?
    var wakeOnLANConfiguration: WakeOnLANConfiguration?
    var autoWakeOnLANEnabled: Bool
    var tags: [String]
    var notes: String?
    var lastConnected: Date?
    var isFavorite: Bool
    var requiresBiometricUnlock: Bool
    var remoteSessionEnabledOverride: Bool?
    var remoteSessionBackendIdentifier: RemoteSessionBackendIdentifier
    var remoteSessionStartupBehaviorOverride: RemoteSessionStartupBehavior?
    var remoteShellStartupAction: RemoteShellStartupAction?
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
        authMethod: AuthMethod? = .password,
        teleportConfiguration: TeleportServerConfiguration? = nil,
        transportConfiguration: ServerTransportConfiguration? = nil,
        iconSelection: ServerIconSelection = .automatic,
        detectedSystemIdentity: RemoteSystemIdentity? = nil,
        cloudflareAccessMode: CloudflareAccessMode? = nil,
        cloudflareTeamDomainOverride: String? = nil,
        cloudflareAppDomainOverride: String? = nil,
        wakeOnLANConfiguration: WakeOnLANConfiguration? = nil,
        autoWakeOnLANEnabled: Bool = false,
        tags: [String] = [],
        notes: String? = nil,
        lastConnected: Date? = nil,
        isFavorite: Bool = false,
        requiresBiometricUnlock: Bool = false,
        remoteSessionEnabledOverride: Bool? = nil,
        remoteSessionBackendIdentifier: RemoteSessionBackendIdentifier = .tmux,
        remoteSessionStartupBehaviorOverride: RemoteSessionStartupBehavior? = nil,
        remoteShellStartupCommand: String? = nil,
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
        self.authMethod = connectionMode.usesSSHAuthentication ? (authMethod ?? .password) : nil
        self.transportConfiguration = transportConfiguration
            ?? (connectionMode == .teleport ? teleportConfiguration.map { .teleport($0) } : nil)
        self.iconSelection = iconSelection
        self.detectedSystemIdentity = detectedSystemIdentity
        self.cloudflareAccessMode = cloudflareAccessMode
        self.cloudflareTeamDomainOverride = cloudflareTeamDomainOverride
        self.cloudflareAppDomainOverride = cloudflareAppDomainOverride
        self.wakeOnLANConfiguration = wakeOnLANConfiguration
        self.autoWakeOnLANEnabled = autoWakeOnLANEnabled
        self.tags = tags
        self.notes = notes
        self.lastConnected = lastConnected
        self.isFavorite = isFavorite
        self.requiresBiometricUnlock = requiresBiometricUnlock
        self.remoteSessionEnabledOverride = remoteSessionEnabledOverride
        self.remoteSessionBackendIdentifier = remoteSessionBackendIdentifier
        self.remoteSessionStartupBehaviorOverride = remoteSessionStartupBehaviorOverride
        self.remoteShellStartupAction = remoteShellStartupCommand.flatMap {
            try? RemoteShellStartupAction(command: $0)
        }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayAddress: String {
        if connectionMode == .teleport, let teleportConfiguration {
            return "\(username)@\(teleportConfiguration.nodeID)"
        }
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
        case transportConfiguration
        case teleportConfiguration
        case iconSelection
        case detectedSystemIdentity
        case cloudflareAccessMode
        case cloudflareTeamDomainOverride
        case cloudflareAppDomainOverride
        case wakeOnLANConfiguration
        case autoWakeOnLANEnabled
        case tags
        case notes
        case lastConnected
        case isFavorite
        case requiresBiometricUnlock
        case tmuxEnabledOverride
        case tmuxStartupBehaviorOverride
        case remoteSessionEnabledOverride
        case remoteSessionBackendIdentifier
        case remoteSessionStartupBehaviorOverride
        case remoteShellStartupCommand
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
        if container.contains(.transportConfiguration) {
            transportConfiguration = try container.decode(
                ServerTransportConfiguration.self, forKey: .transportConfiguration
            )
        } else if connectionMode == .teleport, container.contains(.teleportConfiguration) {
            // A device build saved this format before the generic transport field existed.
            let configuration = try container.decode(
                TeleportServerConfiguration.self, forKey: .teleportConfiguration
            )
            guard try JSONEncoder().encode(configuration).count <= ServerTransportConfiguration.maximumSettingsSize else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Saved transport configuration exceeds its size limit."
                ))
            }
            transportConfiguration = .teleport(configuration)
        } else {
            transportConfiguration = nil
        }
        if connectionMode == .teleport, transportConfiguration == nil {
            throw DecodingError.keyNotFound(CodingKeys.transportConfiguration, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Teleport requires transport settings."
            ))
        }
        if connectionMode.usesSSHAuthentication {
            authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        } else {
            authMethod = nil
        }
        iconSelection = (try? container.decode(
            ServerIconSelection.self,
            forKey: .iconSelection
        )) ?? .automatic
        detectedSystemIdentity = try? container.decode(
            RemoteSystemIdentity.self,
            forKey: .detectedSystemIdentity
        )
        if let rawCloudflareMode = try container.decodeIfPresent(String.self, forKey: .cloudflareAccessMode) {
            cloudflareAccessMode = CloudflareAccessMode(rawValue: rawCloudflareMode)
        } else {
            cloudflareAccessMode = nil
        }
        cloudflareTeamDomainOverride = try container.decodeIfPresent(String.self, forKey: .cloudflareTeamDomainOverride)
        cloudflareAppDomainOverride = try container.decodeIfPresent(String.self, forKey: .cloudflareAppDomainOverride)
        wakeOnLANConfiguration = try container.decodeIfPresent(
            WakeOnLANConfiguration.self,
            forKey: .wakeOnLANConfiguration
        )
        autoWakeOnLANEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoWakeOnLANEnabled
        ) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        requiresBiometricUnlock = try container.decodeIfPresent(Bool.self, forKey: .requiresBiometricUnlock) ?? false
        let legacyTmuxEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .tmuxEnabledOverride
        )
        let legacyTmuxStartupBehavior = try container.decodeIfPresent(
            String.self,
            forKey: .tmuxStartupBehaviorOverride
        ).flatMap(RemoteSessionStartupBehavior.init(persistedRawValue:))
        remoteSessionEnabledOverride = try container.decodeIfPresent(
            Bool.self,
            forKey: .remoteSessionEnabledOverride
        ) ?? legacyTmuxEnabled
        remoteSessionBackendIdentifier = RemoteSessionBackendIdentifier(
            rawValue: try container.decodeIfPresent(
                String.self,
                forKey: .remoteSessionBackendIdentifier
            ) ?? RemoteSessionBackendIdentifier.tmux.rawValue
        )
        remoteSessionStartupBehaviorOverride = try container.decodeIfPresent(
            String.self,
            forKey: .remoteSessionStartupBehaviorOverride
        ).flatMap(RemoteSessionStartupBehavior.init(persistedRawValue:))
            ?? legacyTmuxStartupBehavior
        remoteShellStartupAction = try container.decodeIfPresent(
            String.self,
            forKey: .remoteShellStartupCommand
        ).flatMap { try? RemoteShellStartupAction(command: $0) }
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
        try container.encodeIfPresent(authMethod, forKey: .authMethod)
        if connectionMode == .teleport, transportConfiguration == nil {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Teleport requires transport settings."
            ))
        }
        try container.encodeIfPresent(transportConfiguration, forKey: .transportConfiguration)
        try container.encode(iconSelection, forKey: .iconSelection)
        try container.encodeIfPresent(
            detectedSystemIdentity,
            forKey: .detectedSystemIdentity
        )
        try container.encodeIfPresent(cloudflareAccessMode, forKey: .cloudflareAccessMode)
        try container.encodeIfPresent(cloudflareTeamDomainOverride, forKey: .cloudflareTeamDomainOverride)
        try container.encodeIfPresent(cloudflareAppDomainOverride, forKey: .cloudflareAppDomainOverride)
        try container.encodeIfPresent(
            wakeOnLANConfiguration,
            forKey: .wakeOnLANConfiguration
        )
        try container.encode(autoWakeOnLANEnabled, forKey: .autoWakeOnLANEnabled)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(requiresBiometricUnlock, forKey: .requiresBiometricUnlock)
        try container.encodeIfPresent(
            remoteSessionEnabledOverride,
            forKey: .remoteSessionEnabledOverride
        )
        try container.encode(
            remoteSessionBackendIdentifier.rawValue,
            forKey: .remoteSessionBackendIdentifier
        )
        try container.encodeIfPresent(
            remoteSessionStartupBehaviorOverride?.rawValue,
            forKey: .remoteSessionStartupBehaviorOverride
        )
        try container.encodeIfPresent(
            remoteShellStartupAction?.command,
            forKey: .remoteShellStartupCommand
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

nonisolated enum SSHConnectionMode: RawRepresentable, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case standard
    case tailscale
    case mosh
    case eternalTerminal
    case cloudflare
    case teleport
    case unsupported(String)

    static let allCases: [Self] = [.standard, .tailscale, .mosh, .eternalTerminal, .cloudflare, .teleport]

    init(rawValue: String) {
        switch rawValue {
        case "standard": self = .standard
        case "tailscale": self = .tailscale
        case "mosh": self = .mosh
        case "eternalTerminal": self = .eternalTerminal
        case "cloudflare": self = .cloudflare
        case "teleport": self = .teleport
        default: self = .unsupported(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .standard: "standard"
        case .tailscale: "tailscale"
        case .mosh: "mosh"
        case .eternalTerminal: "eternalTerminal"
        case .cloudflare: "cloudflare"
        case .teleport: "teleport"
        case .unsupported(let value): value
        }
    }

    var usesSSHAuthentication: Bool {
        switch self {
        case .teleport, .unsupported: false
        default: true
        }
    }

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue)
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
