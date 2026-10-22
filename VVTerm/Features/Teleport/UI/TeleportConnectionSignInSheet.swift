import SwiftUI

struct TeleportConnectionSignInSheet: View {
    let request: TeleportConnectionSignInCoordinator.Request
    let coordinator: TeleportConnectionSignInCoordinator
    let service: TeleportAccessService
    let credentials: any ServerCredentialRepository
    @StateObject private var model: TeleportProfileModel
    @EnvironmentObject private var appLock: AppLockManager
    @State private var password = ""
    @State private var passwordLoadFailed = false

    init(
        request: TeleportConnectionSignInCoordinator.Request,
        coordinator: TeleportConnectionSignInCoordinator,
        service: TeleportAccessService,
        credentials: any ServerCredentialRepository,
        model: TeleportProfileModel
    ) {
        self.request = request
        self.coordinator = coordinator
        self.service = service
        self.credentials = credentials
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.server.name)
                    Text(model.profile.account)
                        .foregroundStyle(.secondary)
                    Text(model.profile.proxyURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if passwordLoadFailed {
                    Text("Saved password could not be read. Enter it to sign in.")
                        .foregroundStyle(.orange)
                }
                TeleportProfileSection(
                    model: model, service: service, password: $password,
                    clusterName: .constant(request.server.teleportConfiguration?.clusterName ?? ""),
                    nodeID: .constant(request.server.teleportConfiguration?.nodeID ?? ""),
                    login: .constant(request.server.username), onSelectNode: { _ in },
                    showsServerSelection: false
                )
                if let summary = model.summary, summary.validBefore > Date(),
                   !TeleportConnectionSignInCoordinator.isUsable(summary, for: request.server, at: Date()) {
                    Text("This access does not match the saved cluster or SSH login.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Sign in to Teleport")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.cancel(request.id) }
                }
            }
        }
        .accessibilityIdentifier("vvterm.teleport.connectionSignIn")
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 460, minHeight: 340)
        #endif
        .task {
            do {
                let saved = try credentials.getCredentials(for: request.server)
                if saved.isAuthorized(for: request.server) {
                    password = saved.password ?? ""
                } else {
                    passwordLoadFailed = true
                }
            }
            catch { passwordLoadFailed = true }
            if model.discovery == nil { model.load() }
        }
        .task(id: model.operation) {
            guard model.operation == .idle,
                  TeleportConnectionSignInCoordinator.isUsable(model.summary, for: request.server, at: Date()) else { return }
            // A browser can outlast this saved server's local approval.
            guard await appLock.ensureServerUnlocked(request.server), !Task.isCancelled else {
                coordinator.cancel(request.id)
                return
            }
            _ = await coordinator.complete(request.id)
        }
        .onDisappear {
            model.cancel()
            password = ""
            coordinator.cancel(request.id)
        }
    }
}
