import Foundation

nonisolated enum ServerTransportSelection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case standard
    case tailscale
    case mosh
    case eternalTerminal
    case cloudflare
    case teleport
    case unsupported

    static let allCases: [Self] = [.standard, .tailscale, .mosh, .eternalTerminal, .cloudflare, .teleport]

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
        case .teleport:
            return .teleport
        case .unsupported:
            return .unsupported("unsupported")
        }
    }

    init(server: Server) {
        guard server.isTransportSupported else {
            self = .unsupported
            return
        }
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
        case .teleport:
            self = .teleport
        case .unsupported:
            self = .unsupported
        }
    }
}

nonisolated struct ServerFormModel: Equatable, Sendable {
    nonisolated enum WakeOnLANSavePlan: Equatable, Sendable {
        case clearConfiguration
        case configured(WakeOnLANConfiguration)
        case resolveAutomatically
    }

    nonisolated struct ConnectionSnapshot: Equatable, Sendable {
        let host: String
        let port: String
        let eternalTerminalPort: String
        let username: String
        let transportSelection: ServerTransportSelection
        let teleportConfiguration: TeleportServerConfiguration?
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
    var teleportProxyURL: String
    var teleportAccount: String
    var teleportConnectorID: String
    var teleportClusterName: String
    var teleportNodeID: String
    var authMethod: AuthMethod
    var iconSelection: ServerIconSelection
    private(set) var detectedSystemIdentity: RemoteSystemIdentity?
    var password: String
    var sshKey: String
    var sshPassphrase: String
    var sshPublicKey: String
    var cloudflareAccessMode: CloudflareAccessMode
    var cloudflareClientID: String
    var cloudflareClientSecret: String
    var cloudflareTeamDomainOverride: String
    var cloudflareAppDomainOverride: String
    var autoWakeOnLANEnabled: Bool
    var workspaceID: UUID?
    var environment: ServerEnvironment
    var notes: String
    var requiresBiometricUnlock: Bool
    var remoteSessionEnabled: Bool
    var remoteSessionBackendIdentifier: RemoteSessionBackendIdentifier
    var remoteSessionStartupBehavior: RemoteSessionStartupBehavior
    var remoteShellStartupAction: RemoteShellStartupActionFormModel
    private var detectedSystemEndpoint: ServerRemoteEndpoint?

    init(
        server: Server? = nil,
        workspaceID: UUID? = nil,
        defaultRemoteSessionEnabled: Bool,
        defaultRemoteSessionBackendIdentifier: RemoteSessionBackendIdentifier,
        defaultRemoteSessionStartupBehavior: RemoteSessionStartupBehavior
    ) {
        name = server?.name ?? ""
        host = server?.host ?? ""
        port = String(server?.port ?? 22)
        eternalTerminalPort = String(server?.eternalTerminalPort ?? 2022)
        username = server?.username ?? ""
        transportSelection = server.map(ServerTransportSelection.init) ?? .standard
        teleportProxyURL = server?.teleportConfiguration?.profile.proxyURL ?? ""
        teleportAccount = server?.teleportConfiguration?.profile.account ?? ""
        teleportConnectorID = server?.teleportConfiguration?.profile.connectorID ?? ""
        teleportClusterName = server?.teleportConfiguration?.clusterName ?? ""
        teleportNodeID = server?.teleportConfiguration?.nodeID ?? ""
        authMethod = server?.authMethod ?? .password
        iconSelection = server?.iconSelection ?? .automatic
        detectedSystemIdentity = server?.detectedSystemIdentity
        password = ""
        sshKey = ""
        sshPassphrase = ""
        sshPublicKey = ""
        cloudflareAccessMode = server?.cloudflareAccessMode ?? .oauth
        cloudflareClientID = ""
        cloudflareClientSecret = ""
        cloudflareTeamDomainOverride = server?.cloudflareTeamDomainOverride ?? ""
        cloudflareAppDomainOverride = server?.cloudflareAppDomainOverride ?? ""
        autoWakeOnLANEnabled = server?.autoWakeOnLANEnabled ?? false
        self.workspaceID = server?.workspaceId ?? workspaceID
        environment = server?.environment ?? .production
        notes = server?.notes ?? ""
        requiresBiometricUnlock = server?.requiresBiometricUnlock ?? false
        remoteSessionEnabled = server?.remoteSessionEnabledOverride
            ?? defaultRemoteSessionEnabled
        remoteSessionBackendIdentifier = server?.remoteSessionBackendIdentifier
            ?? defaultRemoteSessionBackendIdentifier
        remoteSessionStartupBehavior = server?.remoteSessionStartupBehaviorOverride
            ?? defaultRemoteSessionStartupBehavior
        remoteShellStartupAction = RemoteShellStartupActionFormModel(
            action: server?.remoteShellStartupAction
        )
        detectedSystemEndpoint = server.flatMap { server in
            guard server.detectedSystemIdentity != nil else { return nil }
            return ServerRemoteEndpoint(server: server)
        }
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasValidEndpoint
            && hasValidCredentials
            && remoteShellStartupAction.isValid(
                remoteSessionEnabled: remoteSessionEnabled
            )
    }

    var teleportProfile: TeleportProfileConfiguration? {
        let input = teleportProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // URLComponents can discard an empty port when it normalizes the host.
        guard !input.hasSuffix(":"), !input.hasSuffix(":/") else { return nil }
        let origin = input.contains("://") ? input : "https://" + input
        return try? TeleportProfileConfiguration(
            proxyURL: origin,
            account: teleportAccount,
            connectorID: teleportConnectorID
        )
    }

    var teleportConfiguration: TeleportServerConfiguration? {
        guard transportSelection == .teleport, let profile = teleportProfile else { return nil }
        return try? TeleportServerConfiguration(
            profile: profile,
            clusterName: teleportClusterName,
            nodeID: teleportNodeID
        )
    }

    private var hasValidEndpoint: Bool {
        guard transportSelection != .unsupported else { return false }
        if transportSelection == .teleport {
            return teleportConfiguration != nil
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !host.isEmpty && validPort(port)
            && (transportSelection != .eternalTerminal || validPort(eternalTerminalPort))
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
            teleportConfiguration: teleportConfiguration,
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

    var currentDetectedSystemIdentity: RemoteSystemIdentity? {
        detectedSystemEndpoint == endpointSnapshot ? detectedSystemIdentity : nil
    }

    func wakeOnLANSavePlan(existingServer: Server?) -> WakeOnLANSavePlan {
        guard transportSelection != .teleport else { return .clearConfiguration }
        if let existingServer,
           Self.normalizedHost(existingServer.host) == Self.normalizedHost(host),
           let configuration = existingServer.wakeOnLANConfiguration {
            return .configured(configuration)
        }
        return autoWakeOnLANEnabled ? .resolveAutomatically : .clearConfiguration
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

    mutating func selectTransport(_ selection: ServerTransportSelection) {
        guard selection != transportSelection else { return }
        if selection == .teleport || transportSelection == .teleport {
            password = ""
        }
        transportSelection = selection
    }

    mutating func apply(_ credentials: ServerCredentials, for server: Server) {
        if server.connectionMode == .teleport || transportSelection == .teleport {
            guard server.connectionMode == .teleport,
                  transportSelection == .teleport,
                  credentials.serverId == server.id,
                  let profile = server.teleportConfiguration?.profile,
                  teleportProfile == profile else { return }
            password = credentials.password ?? ""
            return
        }
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
            case nil:
                break
            }
        }

        sshPublicKey = credentials.publicKey.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        cloudflareClientID = credentials.cloudflareClientID ?? ""
        cloudflareClientSecret = credentials.cloudflareClientSecret ?? ""
    }

    mutating func applyDetectedSystemIdentity(_ identity: RemoteSystemIdentity) {
        detectedSystemIdentity = identity
        detectedSystemEndpoint = endpointSnapshot
    }

    func makeServer(
        id: UUID,
        workspaceID: UUID,
        createdAt: Date
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceID,
            environment: environment,
            name: name,
            host: transportSelection == .teleport ? teleportNodeID : host,
            port: transportSelection == .teleport ? 22 : (Int(port) ?? 22),
            eternalTerminalPort: Int(eternalTerminalPort) ?? 2022,
            username: effectiveUsername,
            connectionMode: transportSelection.connectionMode,
            authMethod: transportSelection == .teleport
                ? nil : (transportSelection == .tailscale ? .password : authMethod),
            teleportConfiguration: teleportConfiguration,
            iconSelection: iconSelection,
            detectedSystemIdentity: currentDetectedSystemIdentity,
            cloudflareAccessMode: transportSelection == .cloudflare ? cloudflareAccessMode : nil,
            cloudflareTeamDomainOverride: transportSelection == .cloudflare
                ? normalizedOptional(cloudflareTeamDomainOverride)
                : nil,
            cloudflareAppDomainOverride: transportSelection == .cloudflare
                ? normalizedOptional(cloudflareAppDomainOverride)
                : nil,
            autoWakeOnLANEnabled: transportSelection == .teleport ? false : autoWakeOnLANEnabled,
            notes: notes.isEmpty ? nil : notes,
            requiresBiometricUnlock: requiresBiometricUnlock,
            remoteSessionEnabledOverride: remoteSessionEnabled,
            remoteSessionBackendIdentifier: remoteSessionBackendIdentifier,
            remoteSessionStartupBehaviorOverride: remoteSessionStartupBehavior,
            remoteShellStartupCommand: remoteShellStartupAction.commandForPersistence(),
            createdAt: createdAt
        )
    }

    func makeCredentials(serverID: UUID) -> ServerCredentials {
        var credentials = ServerCredentials(serverId: serverID)

        if transportSelection == .teleport {
            credentials.password = password.isEmpty ? nil : password
            return credentials
        }

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
        guard transportSelection != .tailscale && transportSelection != .teleport else {
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

    private var endpointSnapshot: ServerRemoteEndpoint {
        ServerRemoteEndpoint(
            host: host,
            sshPort: Int(port),
            connectionMode: transportSelection.connectionMode,
            eternalTerminalPort: Int(eternalTerminalPort),
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: cloudflareAppDomainOverride,
            teleportConfiguration: teleportConfiguration
        )
    }

    private func validPort(_ value: String) -> Bool {
        Int(value).map { (1...65_535).contains($0) } == true
    }

    private static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func nonEmptyData(_ value: String) -> Data? {
        value.isEmpty ? nil : value.data(using: .utf8)
    }
}
