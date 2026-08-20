import Foundation

nonisolated enum ServerTransportSelection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case standard
    case tailscale
    case mosh
    case eternalTerminal
    case cloudflare

    var id: String { rawValue }

    var connectionMode: SSHConnectionMode {
        switch self {
        case .standard:
            return .standard
        case .tailscale:
            return .tailscale
        case .mosh:
            return .mosh
        case .eternalTerminal:
            return .eternalTerminal
        case .cloudflare:
            return .cloudflare
        }
    }

    init(server: Server) {
        switch server.connectionMode {
        case .standard:
            self = .standard
        case .tailscale:
            self = .tailscale
        case .mosh:
            self = .mosh
        case .eternalTerminal:
            self = .eternalTerminal
        case .cloudflare:
            self = .cloudflare
        }
    }
}

nonisolated struct ServerFormModel: Equatable, Sendable {
    nonisolated struct ConnectionSnapshot: Equatable, Sendable {
        let host: String
        let port: String
        let eternalTerminalPort: String
        let username: String
        let transportSelection: ServerTransportSelection
        let authMethod: AuthMethod
        let password: String
        let sshKey: String
        let sshPassphrase: String
        let sshPublicKey: String
        let cloudflareAccessMode: CloudflareAccessMode
        let cloudflareClientID: String
        let cloudflareClientSecret: String
        let cloudflareTeamDomainOverride: String
    }

    var name: String
    var host: String
    var port: String
    var eternalTerminalPort: String
    var username: String
    var transportSelection: ServerTransportSelection
    var authMethod: AuthMethod
    var password: String
    var sshKey: String
    var sshPassphrase: String
    var sshPublicKey: String
    var cloudflareAccessMode: CloudflareAccessMode
    var cloudflareClientID: String
    var cloudflareClientSecret: String
    var cloudflareTeamDomainOverride: String
    var workspaceID: UUID?
    var environment: ServerEnvironment
    var notes: String
    var requiresBiometricUnlock: Bool
    var tmuxEnabled: Bool
    var tmuxStartupBehavior: TmuxStartupBehavior

    init(
        server: Server? = nil,
        workspaceID: UUID? = nil,
        defaultTmuxEnabled: Bool,
        defaultTmuxStartupBehavior: TmuxStartupBehavior
    ) {
        name = server?.name ?? ""
        host = server?.host ?? ""
        port = String(server?.port ?? 22)
        eternalTerminalPort = String(server?.eternalTerminalPort ?? 2022)
        username = server?.username ?? ""
        transportSelection = server.map(ServerTransportSelection.init) ?? .standard
        authMethod = server?.authMethod ?? .password
        password = ""
        sshKey = ""
        sshPassphrase = ""
        sshPublicKey = ""
        cloudflareAccessMode = server?.cloudflareAccessMode ?? .oauth
        cloudflareClientID = ""
        cloudflareClientSecret = ""
        cloudflareTeamDomainOverride = server?.cloudflareTeamDomainOverride ?? ""
        self.workspaceID = server?.workspaceId ?? workspaceID
        environment = server?.environment ?? .production
        notes = server?.notes ?? ""
        requiresBiometricUnlock = server?.requiresBiometricUnlock ?? false
        tmuxEnabled = server?.tmuxEnabledOverride ?? defaultTmuxEnabled
        tmuxStartupBehavior = server?.tmuxStartupBehaviorOverride ?? defaultTmuxStartupBehavior
    }

    var isValid: Bool {
        !name.isEmpty
            && !host.isEmpty
            && validPort(port)
            && (transportSelection != .eternalTerminal || validPort(eternalTerminalPort))
            && hasValidCredentials
    }

    var effectiveUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
    }

    var connectionSnapshot: ConnectionSnapshot {
        ConnectionSnapshot(
            host: host,
            port: port,
            eternalTerminalPort: eternalTerminalPort,
            username: effectiveUsername,
            transportSelection: transportSelection,
            authMethod: authMethod,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase,
            sshPublicKey: sshPublicKey,
            cloudflareAccessMode: cloudflareAccessMode,
            cloudflareClientID: cloudflareClientID,
            cloudflareClientSecret: cloudflareClientSecret,
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride
        )
    }

    mutating func applyPrefill(
        name: String,
        host: String,
        port: Int,
        username: String?
    ) {
        self.name = name
        self.host = host
        self.port = String(port)
        if let username, !username.isEmpty {
            self.username = username
        }
    }

    mutating func apply(_ credentials: ServerCredentials, for server: Server) {
        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                password = credentials.password ?? ""
            case .sshKey, .sshKeyWithPassphrase:
                if let privateKey = credentials.privateKey,
                   let key = String(data: privateKey, encoding: .utf8) {
                    sshKey = key
                }
                if server.authMethod == .sshKeyWithPassphrase {
                    sshPassphrase = credentials.passphrase ?? ""
                }
            }
        }

        sshPublicKey = credentials.publicKey.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        cloudflareClientID = credentials.cloudflareClientID ?? ""
        cloudflareClientSecret = credentials.cloudflareClientSecret ?? ""
    }

    func makeServer(id: UUID, workspaceID: UUID, createdAt: Date) -> Server {
        Server(
            id: id,
            workspaceId: workspaceID,
            environment: environment,
            name: name,
            host: host,
            port: Int(port) ?? 22,
            eternalTerminalPort: Int(eternalTerminalPort) ?? 2022,
            username: effectiveUsername,
            connectionMode: transportSelection.connectionMode,
            authMethod: transportSelection == .tailscale ? .password : authMethod,
            cloudflareAccessMode: transportSelection == .cloudflare ? cloudflareAccessMode : nil,
            cloudflareTeamDomainOverride: transportSelection == .cloudflare
                ? normalizedOptional(cloudflareTeamDomainOverride)
                : nil,
            cloudflareAppDomainOverride: nil,
            notes: notes.isEmpty ? nil : notes,
            requiresBiometricUnlock: requiresBiometricUnlock,
            tmuxEnabledOverride: tmuxEnabled,
            tmuxStartupBehaviorOverride: tmuxStartupBehavior,
            createdAt: createdAt
        )
    }

    func makeCredentials(serverID: UUID) -> ServerCredentials {
        var credentials = ServerCredentials(serverId: serverID)

        guard transportSelection != .tailscale else {
            return credentials
        }

        switch authMethod {
        case .password:
            credentials.password = password
        case .sshKey:
            credentials.sshKey = sshKey.data(using: .utf8)
            credentials.publicKey = nonEmptyData(sshPublicKey)
        case .sshKeyWithPassphrase:
            credentials.sshKey = sshKey.data(using: .utf8)
            credentials.sshPassphrase = sshPassphrase
            credentials.publicKey = nonEmptyData(sshPublicKey)
        }

        if transportSelection == .cloudflare, cloudflareAccessMode == .serviceToken {
            credentials.cloudflareClientID = normalizedOptional(cloudflareClientID)
            credentials.cloudflareClientSecret = normalizedOptional(cloudflareClientSecret)
        }

        return credentials
    }

    private var hasValidCredentials: Bool {
        guard transportSelection != .tailscale else {
            return true
        }

        if transportSelection == .cloudflare,
           cloudflareAccessMode == .serviceToken,
           (normalizedOptional(cloudflareClientID) == nil
                || normalizedOptional(cloudflareClientSecret) == nil) {
            return false
        }

        switch authMethod {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return !sshKey.isEmpty
        case .sshKeyWithPassphrase:
            return !sshKey.isEmpty && !sshPassphrase.isEmpty
        }
    }

    private func validPort(_ value: String) -> Bool {
        Int(value).map { (1...65_535).contains($0) } == true
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func nonEmptyData(_ value: String) -> Data? {
        value.isEmpty ? nil : value.data(using: .utf8)
    }
}
