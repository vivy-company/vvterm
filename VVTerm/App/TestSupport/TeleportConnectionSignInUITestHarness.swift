#if DEBUG && os(iOS)
import Foundation
import SwiftUI
import TeleportKit

/// Exercises the real task owner and error alert with memory-only access.
@MainActor
struct TeleportConnectionSignInUITestHarness: View {
    private enum Outcome: String { case idle, waiting, connected, cancelled }
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

    private static let fixture: (server: Server, stored: StoredSummary) = {
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
            return (server, StoredSummary(expired))
        } catch {
            preconditionFailure("Invalid fixed Teleport renewal UI profile")
        }
    }()

    var body: some View {
        NavigationStack {
            Form {
                Button("Connect") {
                    outcome = .waiting
                    connectionTask = Task {
                        let allowed = await coordinator.ensureAccess(for: Self.fixture.server)
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
        .modifier(TeleportConnectionSignInHost(coordinator: coordinator) { _, _ in
            try await Self.fixture.stored.authenticate(
                failFirst: Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-renewal-failure")
            )
        })
        .onDisappear {
            connectionTask?.cancel()
            coordinator.cancel()
        }
    }

    private actor StoredSummary {
        private var value: TeleportAccessSummary
        private var isFirstAttempt = true
        init(_ value: TeleportAccessSummary) { self.value = value }
        func read() -> TeleportAccessSummary { value }
        func authenticate(failFirst: Bool) throws {
            defer { isFirstAttempt = false }
            if failFirst && isFirstAttempt { throw TeleportError.accessDenied }
            value = TeleportAccessSummary(
                account: value.account, clusterName: value.clusterName,
                validBefore: .distantFuture, allowedLogins: value.allowedLogins
            )
        }
    }
}
#endif
