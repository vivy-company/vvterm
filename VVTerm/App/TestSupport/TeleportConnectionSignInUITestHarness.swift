#if DEBUG && os(iOS)
import Foundation
import SwiftUI
import TeleportKit

/// Exercises the real renewal sheet and continuation without authentication or persistence.
@MainActor
struct TeleportConnectionSignInUITestHarness: View {
    private enum Outcome: String { case idle, waiting, connected, cancelled }
    private var server: Server { Self.fixture.server }
    private var expired: TeleportAccessSummary { Self.fixture.expired }
    private var stored: StoredSummary { Self.fixture.stored }
    private var service: TeleportAccessService { Self.fixture.service }
    @StateObject private var coordinator: TeleportConnectionSignInCoordinator
    @State private var outcome = Outcome.idle
    @State private var connectionTask: Task<Void, Never>?

    init() {
        let fixture = Self.fixture
        _coordinator = StateObject(wrappedValue: TeleportConnectionSignInCoordinator(
            summary: { _ in await fixture.stored.read() },
            currentServer: { $0 == fixture.server.id ? fixture.server : nil },
            now: Date.init
        ))
    }

    // A View can be rebuilt while its StateObject remains alive.
    private static let fixture: (
        server: Server, expired: TeleportAccessSummary,
        stored: StoredSummary, service: TeleportAccessService
    ) = {
        do {
            let profile = try TeleportProfileConfiguration(
                proxyURL: "https://proxy.example.invalid", account: "ui-test-user"
            )
            let configuration = try TeleportServerConfiguration(
                profile: profile, clusterName: "ui-test-cluster", nodeID: "ui-test-node"
            )
            let server = Server(
                workspaceId: UUID(), name: "Renewal UI server", host: configuration.nodeID,
                username: "ui-test-login", connectionMode: .teleport,
                teleportConfiguration: configuration
            )
            let expired = TeleportAccessSummary(
                account: profile.account, clusterName: configuration.clusterName,
                validBefore: .distantPast, allowedLogins: [server.username]
            )
            let stored = StoredSummary(expired)
            let service = TeleportAccessService(
                keychain: KeychainStore(service: "test.teleport.renewal.ui", backing: UnusedKeychain()),
                makeBrowserSession: { _, _ in preconditionFailure("This UI check must not open a browser") },
                didSignOut: { _ in }
            )
            return (server, expired, stored, service)
        } catch {
            preconditionFailure("Invalid fixed Teleport renewal UI profile")
        }
    }()

    var body: some View {
        let requestID = coordinator.request?.id
        NavigationStack {
            Form {
                Button("Connect") {
                    outcome = .waiting
                    connectionTask = Task {
                        let allowed = await coordinator.ensureAccess(for: server)
                        outcome = allowed ? .connected : .cancelled
                        connectionTask = nil
                    }
                }
                .accessibilityIdentifier("vvterm.teleport.renewalTest.connect")
                .disabled(outcome == .waiting)
                Text(outcome.rawValue)
                    .accessibilityIdentifier("vvterm.teleport.renewalTest.outcome")
            }
            .navigationTitle("Teleport renewal test")
        }
        .sheet(item: Binding(
            get: { coordinator.request },
            set: { if $0 == nil, let requestID { coordinator.cancel(requestID) } }
        )) { request in
            if let profile = request.server.teleportConfiguration?.profile {
                TeleportConnectionSignInSheet(
                    request: request, coordinator: coordinator, service: service,
                    credentials: SavedPassword(),
                    model: TeleportProfileModel(
                        profile: profile, service: service, summary: expired,
                        discovery: TeleportDiscovery(
                            clusterName: expired.clusterName, serverVersion: "18.11.4",
                            authenticationType: "local", secondFactor: "otp", connectors: [],
                            webAuthnConfigured: true
                        )
                    )
                )
                .safeAreaInset(edge: .bottom) {
                    Button("Finish test sign-in") {
                        Task {
                            await stored.approve()
                            _ = await coordinator.complete(request.id)
                        }
                    }
                    .accessibilityIdentifier("vvterm.teleport.renewalTest.finish")
                    .padding()
                }
            }
        }
        .onDisappear {
            connectionTask?.cancel()
            coordinator.cancel()
        }
    }

    private actor StoredSummary {
        private var value: TeleportAccessSummary
        init(_ value: TeleportAccessSummary) { self.value = value }
        func read() -> TeleportAccessSummary { value }
        func approve() {
            value = TeleportAccessSummary(
                account: value.account, clusterName: value.clusterName,
                validBefore: .distantFuture, allowedLogins: value.allowedLogins
            )
        }
    }

    private nonisolated enum Failure: Error { case unexpectedExternalOperation }

    @MainActor
    private final class SavedPassword: ServerCredentialRepository {
        func getCredentials(for server: Server) throws -> ServerCredentials {
            ServerCredentials(
                serverId: server.id, credentialBinding: ServerCredentialBinding(server: server),
                password: "UI-ONLY-SAVED-PASSWORD"
            )
        }
        func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
            throw Failure.unexpectedExternalOperation
        }
        func deleteCredentials(for serverID: UUID) throws { throw Failure.unexpectedExternalOperation }
        func getStoredSSHKeys() -> [SSHKeyEntry] { [] }
        func getStoredSSHKeyData(for id: UUID) throws -> (key: Data, passphrase: String?)? {
            throw Failure.unexpectedExternalOperation
        }
    }

    private nonisolated struct UnusedKeychain: KeychainStoreBacking {
        func set(_ data: Data, service: String, key: String, scope: KeychainStorageScope) throws {
            throw Failure.unexpectedExternalOperation
        }
        func get(service: String, key: String, scope: KeychainStorageScope) throws -> Data? {
            throw Failure.unexpectedExternalOperation
        }
        func contains(service: String, key: String, scope: KeychainStorageScope) throws -> Bool {
            throw Failure.unexpectedExternalOperation
        }
        func delete(service: String, key: String, scope: KeychainStorageScope) throws {
            throw Failure.unexpectedExternalOperation
        }
        func keys(service: String, scope: KeychainStorageScope) throws -> [String] {
            throw Failure.unexpectedExternalOperation
        }
    }
}
#endif
