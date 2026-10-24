import SwiftUI

struct TeleportDeviceCredentialControls: View {
    @ObservedObject var model: TeleportProfileModel
    @State private var showsRemoval = false

    var body: some View {
        Group {
            Button("Remove device key…", role: .destructive) { showsRemoval = true }
                .accessibilityIdentifier("vvterm.teleport.credential.remove")
                .disabled(model.isBusy)
            if let failure = model.failure, failure.operation == .deletingCredential {
                Text(failure.message).foregroundStyle(.red)
            }
            if model.operation == .deletingCredential {
                ProgressView("Removing device key…")
            }
        }
        .confirmationDialog("Remove device key?", isPresented: $showsRemoval) {
            Button("Remove device key", role: .destructive) { model.deleteSecureEnclaveCredential() }
        } message: {
            Text("The key is removed from this device only. Remove its entry in Teleport before you set up this device again. Issued access stays valid.")
        }
    }
}
