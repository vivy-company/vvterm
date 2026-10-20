import AuthenticationServices
import Foundation
import TeleportKit

actor TeleportAccessService {
    typealias BrowserFactory = @MainActor @Sendable (
        _ anchor: ASPresentationAnchor,
        _ onCancel: @escaping @MainActor @Sendable () -> Void
    ) -> any TeleportBrowserSession

    private nonisolated enum ProfileState {
        case ready(TeleportClient)
        case signingIn(TeleportClient)
        case signingOut(TeleportClient)
    }

    private nonisolated final class WeakConnection {
        weak var value: TeleportSSHPreparedConnection?
        init(_ value: TeleportSSHPreparedConnection) { self.value = value }
    }

    nonisolated let makeBrowserSession: BrowserFactory
    private let keychain: KeychainStore
    private let didSignOut: @MainActor @Sendable (String) -> Void
    private var profiles: [String: ProfileState] = [:]
    private var connections: [String: [WeakConnection]] = [:]

    init(
        keychain: KeychainStore,
        makeBrowserSession: @escaping BrowserFactory,
        didSignOut: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.keychain = keychain
        self.makeBrowserSession = makeBrowserSession
        self.didSignOut = didSignOut
    }

    func summary(for profile: TeleportProfileConfiguration) async throws -> TeleportAccessSummary? {
        if case .signingOut = profiles[profile.identifier] { return nil }
        let client = try configuredClient(profile)
        guard let identity = try await identityStore(profile.identifier).load() else { return nil }
        guard isCurrentClient(client, profileID: profile.identifier) else { return nil }
        return TeleportAccessSummary(identity: identity)
    }

    func discovery(for profile: TeleportProfileConfiguration) async throws -> TeleportDiscovery {
        let client = try configuredClient(profile)
        let discovery = try await client.discover()
        try validateCurrentClient(client, profileID: profile.identifier)
        return discovery
    }

    func login(profile: TeleportProfileConfiguration, password: String, otp: String) async throws -> TeleportAccessSummary {
        try await performLogin(profile: profile) { client in
            try await client.login(username: profile.account, password: password, otp: otp)
        }
    }

    func login(
        profile: TeleportProfileConfiguration,
        connector: TeleportConnector,
        presenter: any TeleportBrowserPresenter
    ) async throws -> TeleportAccessSummary {
        try await performLogin(profile: profile) { client in
            try await client.login(browser: presenter, connector: connector)
        }
    }

    /// One form owns a login attempt and its browser. A second form must not
    /// join a package task whose browser the first form can close independently.
    func performLogin(
        profile: TeleportProfileConfiguration,
        operation: @Sendable (TeleportClient) async throws -> TeleportIdentity
    ) async throws -> TeleportAccessSummary {
        try Task.checkCancellation()
        if case .signingIn = profiles[profile.identifier] {
            throw TeleportAccessError.loginInProgress
        }
        let client = try configuredClient(profile)
        profiles[profile.identifier] = .signingIn(client)
        defer {
            if case .signingIn(let current) = profiles[profile.identifier], current === client {
                profiles[profile.identifier] = .ready(client)
            }
        }
        let identity = try await operation(client)
        try validateCurrentClient(client, profileID: profile.identifier)
        return TeleportAccessSummary(identity: identity)
    }

    func nodes(for profile: TeleportProfileConfiguration, startKey: String = "") async throws -> TeleportNodePage {
        let client = try configuredClient(profile)
        let page = try await client.nodes(limit: 100, startKey: startKey)
        try validateCurrentClient(client, profileID: profile.identifier)
        return page
    }

    func signOut(profile: TeleportProfileConfiguration) async throws {
        let client = try configuredClient(profile)
        profiles[profile.identifier] = .signingOut(client)
        await didSignOut(profile.identifier)
        for connection in connections.removeValue(forKey: profile.identifier) ?? [] {
            await connection.value?.close()
        }
        do {
            try await client.signOut()
            profiles.removeValue(forKey: profile.identifier)
        } catch {
            profiles[profile.identifier] = .ready(client)
            throw error
        }
    }

    func prepare(_ request: SSHPreparedConnectionRequest) async throws -> any SSHPreparedConnection {
        do {
            let client = try await storedClient(request.profileID)
            let identity = try await client.identity()
            guard identity.clusterName == request.clusterName else {
                throw TeleportError.invalidCertificate("root cluster")
            }
            let node = try await client.resolveNode(request.nodeID)
            guard node.id == request.nodeID, node.clusterName == request.clusterName else {
                throw TeleportError.nodeNotFound
            }
            let connection = try await client.connect(to: node, login: request.login)
            guard isCurrentClient(client, profileID: request.profileID), !Task.isCancelled else {
                await connection.close()
                throw CancellationError()
            }
            let prepared = TeleportSSHPreparedConnection(connection: connection)
            connections[request.profileID] = (connections[request.profileID] ?? []).filter { $0.value != nil }
                + [WeakConnection(prepared)]
            return prepared
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SSHError.connectionFailed(TeleportAccessError.message(for: error))
        }
    }

    private func identityStore(_ profileID: String) -> TeleportKeychainIdentityStore {
        TeleportKeychainIdentityStore(keychain: keychain, profileID: profileID)
    }

    private func validateCurrentClient(_ client: TeleportClient, profileID: String) throws {
        try Task.checkCancellation()
        guard isCurrentClient(client, profileID: profileID) else {
            throw TeleportError.authenticationRequired
        }
    }

    private func isCurrentClient(_ client: TeleportClient, profileID: String) -> Bool {
        switch profiles[profileID] {
        case .ready(let current), .signingIn(let current): return current === client
        case .signingOut, nil: return false
        }
    }

    private func configuredClient(_ profile: TeleportProfileConfiguration) throws -> TeleportClient {
        switch profiles[profile.identifier] {
        case .ready(let client), .signingIn(let client): return client
        case .signingOut: throw TeleportError.authenticationRequired
        case nil:
            guard let url = URL(string: profile.proxyURL) else {
                throw TeleportError.invalidConfiguration("proxy origin")
            }
            let client = TeleportClient(proxy: try TeleportProxy(url: url), identityStore: identityStore(profile.identifier))
            profiles[profile.identifier] = .ready(client)
            return client
        }
    }

    private func storedClient(_ profileID: String) async throws -> TeleportClient {
        switch profiles[profileID] {
        case .ready(let client), .signingIn(let client): return client
        case .signingOut: throw TeleportError.authenticationRequired
        case nil: break
        }
        let store = identityStore(profileID)
        guard let identity = try await store.load(), identity.isUsable() else {
            throw TeleportError.authenticationRequired
        }
        switch profiles[profileID] {
        case .ready(let client), .signingIn(let client): return client
        case .signingOut: throw TeleportError.authenticationRequired
        case nil:
            let client = TeleportClient(proxy: identity.proxy, identityStore: store)
            profiles[profileID] = .ready(client)
            return client
        }
    }
}
