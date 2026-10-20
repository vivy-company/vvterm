import SwiftUI
import TeleportKit

/// The library owns enrollment and key use. This view owns only form values and presentation.
struct TeleportDeviceCredentialControls: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel
    @Binding var password: String
    let onSignIn: () -> Void

    private enum Presentation: Equatable { case setup, removal }
    @State private var presentation: Presentation?

    var body: some View {
        Section {
            Text("Use a credential already set up on this device. Your Teleport password is still required.")
                .foregroundStyle(.secondary)
            if model.discovery?.authenticationType == "local" {
                SecureField("Teleport password", text: $password)
                    .accessibilityIdentifier("vvterm.teleport.credential.password")
                    .disabled(model.isBusy)
                Button("Sign in with Face ID or Touch ID", action: onSignIn)
                    .accessibilityIdentifier("vvterm.teleport.credential.signIn")
                    .disabled(model.isBusy || password.isEmpty)
            }
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
            if let result = model.credentialResult {
                switch result {
                case .registered:
                    Text("Device credential registered. Use your password and Face ID or Touch ID to sign in.")
                case .deleted:
                    Text("Local device credential removed. Remove its server entry in Teleport separately.")
                case .codeRequired:
                    EmptyView()
                }
            }
        } header: {
            Text("Device biometric sign-in")
                .accessibilityIdentifier("vvterm.teleport.credential.controls")
        } footer: {
            Text("Keep another sign-in method for recovery. If this device key is lost, sign in another way and remove its old entry in Teleport before setup again.")
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
                .disabled(model.isBusy)
            if model.credentialResult == .codeRequired {
                SecureField("Fresh one-time code", text: $otp)
                    .accessibilityIdentifier("vvterm.teleport.credential.otp")
                    .disabled(model.isBusy)
                Text("Wait for a new code from your authenticator app after login. Teleport cannot use the same code twice.")
                    .foregroundStyle(.secondary)
                Button("Enable biometric sign-in") {
                    model.registerSecureEnclaveCredential(name: name, otp: otp)
                    otp = ""
                }
                .accessibilityIdentifier("vvterm.teleport.credential.enable")
                .disabled(!validName || model.isBusy || !TeleportProfileModel.isValidOneTimeCode(otp))
            } else {
                Button("Continue setup") {
                    model.registerSecureEnclaveCredential(name: name)
                    otp = ""
                }
                .accessibilityIdentifier("vvterm.teleport.credential.continue")
                .disabled(!validName || model.isBusy)
            }
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
                    otp = ""
                }
                .disabled(!validName || model.isBusy)
                .background {
                    TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Button("Cancel device setup") {
                model.cancelCredentialSetup()
                close()
            }
            .accessibilityIdentifier("vvterm.teleport.credential.cancel")
        }
        .onChange(of: model.credentialResult) { result in
            if result == .registered { close() }
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
