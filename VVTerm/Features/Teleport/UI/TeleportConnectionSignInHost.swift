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
        authenticate = { profile, makeBrowserSession in
            guard let service else { throw TeleportError.authenticationRequired }
            _ = try await service.signIn(
                profile: profile,
                prompt: String(localized: "Approve Teleport sign-in with Face ID or Touch ID."),
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
            authorize: { server in await appLock.ensureServerUnlocked(server) }
        )
    }
}
