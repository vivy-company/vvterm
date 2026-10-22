import SwiftUI
import TeleportKit

/// Each app window owns its sign-in request. No transport deadline runs while it is open.
struct TeleportConnectionSignInHost: ViewModifier {
    private let dependencies: ServerFormDependencies
    @StateObject private var coordinator: TeleportConnectionSignInCoordinator

    init(dependencies: ServerFormDependencies, serverManager: ServerManager) {
        self.dependencies = dependencies
        let service = dependencies.teleportAccess
        _coordinator = StateObject(wrappedValue: TeleportConnectionSignInCoordinator(
            summary: { profile in
                guard let service else { throw TeleportError.authenticationRequired }
                return try await service.summary(for: profile)
            },
            currentServer: { id in serverManager.servers.first { $0.id == id } },
            now: dependencies.now
        ))
    }

    func body(content: Content) -> some View {
        let requestID = coordinator.request?.id
        content
            .environmentObject(coordinator)
            .sheet(item: Binding(
                get: { coordinator.request },
                set: { value in
                    if value == nil, let requestID { coordinator.cancel(requestID) }
                }
            )) { request in
                if let service = dependencies.teleportAccess,
                   let profile = request.server.teleportConfiguration?.profile {
                    TeleportConnectionSignInSheet(
                        request: request, coordinator: coordinator, service: service,
                        credentials: dependencies.credentials,
                        model: TeleportProfileModel(profile: profile, service: service)
                    )
                } else {
                    VStack(spacing: 16) {
                        Text("Teleport is not available.")
                        Button("Cancel") { coordinator.cancel(request.id) }
                    }
                    .padding()
                    .onDisappear { coordinator.cancel(request.id) }
                }
            }
            .onDisappear { coordinator.cancel() }
    }
}
