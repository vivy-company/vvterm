import Combine
import SwiftUI
import TeleportKit

/// The window supplies presentation. The coordinator owns authentication and cancellation.
struct TeleportConnectionSignInHost: ViewModifier {
    private let authenticate: TeleportConnectionSignInCoordinator.Authentication
    private let browserFactory: TeleportAccessService.BrowserFactory?
    private let serverUpdates: AnyPublisher<[Server], Never>
    @StateObject private var coordinator: TeleportConnectionSignInCoordinator
    @EnvironmentObject private var appLock: AppLockManager
    @State private var presentationWindow = TeleportPresentationWindow()

    init(dependencies: ServerFormDependencies, serverManager: ServerManager) {
        let service = dependencies.teleportAccess
        browserFactory = service?.makeBrowserSession
        authenticate = { server, makeBrowserSession in
            guard let service, let profile = server.teleportConfiguration?.profile else {
                throw TeleportError.authenticationRequired
            }
            _ = try await service.signIn(
                profile: profile,
                prompt: Self.signInPrompt(serverName: server.name),
                makeBrowserSession: makeBrowserSession
            )
        }
        serverUpdates = serverManager.stateStore.$snapshot.map(\.servers).eraseToAnyPublisher()
        _coordinator = StateObject(wrappedValue: TeleportConnectionSignInCoordinator(
            summary: { profile in
                guard let service else { throw TeleportError.authenticationRequired }
                return try await service.summary(for: profile)
            },
            currentServer: { id in serverManager.servers.first { $0.id == id } },
            now: dependencies.now
        ))
    }

    #if DEBUG
    /// Uses the same presentation and task owner with memory-only authentication.
    init(
        coordinator: TeleportConnectionSignInCoordinator,
        authenticate: @escaping TeleportConnectionSignInCoordinator.Authentication
    ) {
        self.authenticate = authenticate
        browserFactory = nil
        serverUpdates = Empty<[Server], Never>().eraseToAnyPublisher()
        _coordinator = StateObject(wrappedValue: coordinator)
    }
    #endif

    static func signInPrompt(serverName: String) -> String {
        let shortened = String(decoding: serverName.utf8.prefix(160), as: UTF8.self)
        let name = shortened.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? String(localized: "this server") : name
        return String(localized: "Open \(label) and sign in to Teleport with Face ID or Touch ID.")
    }

    func body(content: Content) -> some View {
        let requestID = coordinator.request?.id
        content
            .environmentObject(coordinator)
            .background {
                TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: requestID) { id in
                if let id { signIn(id) }
            }
            .onReceive(serverUpdates) { coordinator.savedServersDidChange($0) }
            .onChange(of: appLock.isAppLocked) { locked in
                if locked { coordinator.cancel() }
            }
            .alert("Teleport sign-in failed", isPresented: Binding(
                get: { coordinator.failureMessage != nil },
                // The actions own completion. Dismissal must not cancel a retry.
                set: { _ in }
            )) {
                if let requestID {
                    Button("Retry") { signIn(requestID) }
                    Button("Cancel", role: .cancel) { coordinator.cancel(requestID) }
                }
            } message: {
                Text(coordinator.failureMessage ?? "")
            }
            .onDisappear { coordinator.cancel() }
    }

    private func signIn(_ requestID: UUID) {
        let window = presentationWindow
        let browserFactory = browserFactory
        let appLock = appLock
        coordinator.signIn(
            requestID, authenticate: authenticate,
            makeBrowserSession: { onCancel in
                guard let browserFactory, let anchor = window.value else {
                    throw TeleportError.transport("browser presentation window")
                }
                return browserFactory(anchor, onCancel)
            },
            authorizeFresh: { server, validate, operation in
                _ = try await appLock.withServerBiometricAuthentication(
                    server, validate: validate, operation: operation
                )
            }
        )
    }
}
