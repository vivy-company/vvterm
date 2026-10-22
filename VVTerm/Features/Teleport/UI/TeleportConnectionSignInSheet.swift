import SwiftUI

struct TeleportConnectionSignInSheet: View {
    let request: TeleportConnectionSignInCoordinator.Request
    let coordinator: TeleportConnectionSignInCoordinator
    let service: TeleportAccessService
    private let startsAutomatically: Bool
    @StateObject private var model: TeleportProfileModel
    @EnvironmentObject private var appLock: AppLockManager

    init(
        request: TeleportConnectionSignInCoordinator.Request,
        coordinator: TeleportConnectionSignInCoordinator,
        service: TeleportAccessService,
        model: TeleportProfileModel,
        startsAutomatically: Bool = true
    ) {
        self.request = request
        self.coordinator = coordinator
        self.service = service
        self.startsAutomatically = startsAutomatically
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
                Section {
                    TeleportSignInButton(service: service, model: model, startsAutomatically: startsAutomatically)
                        .disabled(model.isBusy)
                    if model.isBusy {
                        ProgressView("Signing in…")
                    }
                    if let message = model.errorMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
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
            coordinator.cancel(request.id)
        }
    }
}
