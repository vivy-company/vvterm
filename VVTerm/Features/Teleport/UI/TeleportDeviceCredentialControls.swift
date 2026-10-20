import SwiftUI
import TeleportKit

/// The library owns enrollment and key use. This view owns only form values and presentation.
struct TeleportDeviceCredentialControls: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel

    private enum Presentation: Equatable { case setup, removal }
    @State private var presentation: Presentation?

    var body: some View {
        DisclosureGroup {
            Text("Use your password with Face ID or Touch ID. Keep another sign-in method for recovery.")
                .foregroundStyle(.secondary)
            Button("Set up device credential…") { presentation = .setup }
                .accessibilityIdentifier("vvterm.teleport.credential.setup")
                .disabled(model.isBusy || !model.canRegisterCredential)
            if presentation == .setup {
                TeleportDeviceCredentialSetup(
                    service: service, model: model,
                    onClose: { presentation = nil }
                )
            }
            if !model.canRegisterCredential {
                Text("Sign in to this local account before setup.")
                    .foregroundStyle(.secondary)
            }
            Button("Remove local device credential…", role: .destructive) { presentation = .removal }
                .accessibilityIdentifier("vvterm.teleport.credential.remove")
                .disabled(model.isBusy)
            Text("Local removal does not remove the Teleport entry or revoke issued access. Remove the server entry in Teleport before setup again.")
                .foregroundStyle(.secondary)
        } label: {
            Text("Device biometric sign-in")
                .accessibilityIdentifier("vvterm.teleport.credential.controls")
        }
        .confirmationDialog("Remove this device's Teleport credential?", isPresented: Binding(
            get: { presentation == .removal },
            set: { if !$0 && presentation == .removal { presentation = nil } }
        )) {
            Button("Remove local credential", role: .destructive) {
                model.deleteSecureEnclaveCredential()
            }
        } message: {
            Text("Sign in another way, then remove the server entry in Teleport before setup again. Current access stays valid.")
        }
    }
}

private struct TeleportDeviceCredentialSetup: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel
    let onClose: () -> Void
    @State private var presentationWindow = TeleportPresentationWindow()
    @State private var name = "VVTerm"
    @State private var otp = ""

    var body: some View {
        Group {
            TextField("Device name", text: $name)
                .accessibilityIdentifier("vvterm.teleport.credential.name")
            SecureField("Fresh one-time code", text: $otp)
                .accessibilityIdentifier("vvterm.teleport.credential.otp")
            Text("Enter a fresh code from your authenticator app to approve setup. Face ID or Touch ID will protect the new key on this device.")
                .foregroundStyle(.secondary)
            Button("Enable biometric sign-in") {
                model.registerSecureEnclaveCredential(name: name, otp: otp)
                close()
            }
            .disabled(!validName || model.isBusy)
            if model.discovery?.webAuthnConfigured == true {
                Button("Approve with an existing passkey or security key") {
                    let anchor = presentationWindow.value
                    let service = service
                    model.registerSecureEnclaveCredential(name: name) { onCancel in
                        guard let anchor else {
                            throw TeleportError.transport("browser presentation window")
                        }
                        return service.makeBrowserSession(anchor, onCancel)
                    }
                    close()
                }
                .disabled(!validName || model.isBusy)
                .background {
                    TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Button("Cancel device setup") { close() }
                .accessibilityIdentifier("vvterm.teleport.credential.cancel")
        }
    }

    private func close() {
        otp = ""
        onClose()
    }

    private var validName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 30
    }
}
