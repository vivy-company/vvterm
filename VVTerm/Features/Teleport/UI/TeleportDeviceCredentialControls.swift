import SwiftUI
import TeleportKit

struct TeleportDeviceCredentialControls: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel
    @Binding var password: String
    @Binding var isSigningIn: Bool
    let onSignIn: () -> Void

    private enum Presentation { case setup, removal }
    @State private var presentation: Presentation?

    var body: some View {
        Section {
            if presentation == .setup {
                TeleportDeviceCredentialSetup(service: service, model: model) { presentation = nil }
            } else if isSigningIn {
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("vvterm.teleport.credential.password")
                    .disabled(model.isBusy)
                Button("Sign in", action: onSignIn)
                    .accessibilityIdentifier("vvterm.teleport.credential.signIn")
                    .disabled(model.isBusy || password.isEmpty)
                Button("Use another method") {
                    password = ""
                    isSigningIn = false
                }
                .disabled(model.isBusy)
            } else {
                Button("Use Face ID or Touch ID") { isSigningIn = true }
                    .accessibilityIdentifier("vvterm.teleport.credential.use")
                    .disabled(model.isBusy)
            }
            if let failure = model.failure, showsFailure(for: failure.operation) {
                Text(failure.message).foregroundStyle(.red)
            }
            if model.isBusy && model.operation.isDeviceAuthentication {
                ProgressView(progressLabel)
                if model.operation == .biometricLogin {
                    Button("Cancel") { model.cancel() }
                }
            }
            if model.credentialResult == .registered {
                Text("Device added.").foregroundStyle(.secondary)
            } else if model.credentialResult == .deleted {
                Text("Device removed.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Biometric sign-in")
                    .accessibilityIdentifier("vvterm.teleport.credential.controls")
                Spacer()
                Menu("Manage") {
                    Button(model.canRegisterCredential ? "Set up this device" : "Sign in before setup") {
                        password = ""
                        isSigningIn = false
                        presentation = .setup
                    }
                    .accessibilityIdentifier("vvterm.teleport.credential.setup")
                    .disabled(!model.canRegisterCredential)
                    Button("Remove from this device…", role: .destructive) {
                        password = ""
                        isSigningIn = false
                        presentation = .removal
                    }
                        .accessibilityIdentifier("vvterm.teleport.credential.remove")
                }
                .accessibilityIdentifier("vvterm.teleport.credential.manage")
                .disabled(model.isBusy)
                .textCase(nil)
            }
        }
        .confirmationDialog("Remove local key?", isPresented: Binding(
            get: { presentation == .removal },
            set: { if !$0 && presentation == .removal { presentation = nil } }
        )) {
            Button("Remove local key", role: .destructive) { model.deleteSecureEnclaveCredential() }
        } message: {
            Text("Access stays valid. Keep another sign-in method. Remove the device entry in Teleport before setup again.")
        }
    }

    private func showsFailure(for operation: TeleportProfileModel.Operation) -> Bool {
        switch operation {
        case .biometricLogin: isSigningIn
        case .registeringCredential: presentation == .setup
        case .deletingCredential: true
        default: false
        }
    }

    private var progressLabel: LocalizedStringKey {
        switch model.operation {
        case .biometricLogin: "Signing in…"
        case .registeringCredential: "Setting up…"
        default: "Removing…"
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
                SecureField("Authenticator code", text: $otp)
                    .accessibilityIdentifier("vvterm.teleport.credential.otp")
                    .disabled(model.isBusy)
                Text("Use a new code after login.")
                    .foregroundStyle(.secondary)
                Button("Set up") {
                    model.registerSecureEnclaveCredential(name: name, otp: otp)
                    otp = ""
                }
                .accessibilityIdentifier("vvterm.teleport.credential.enable")
                .disabled(!validName || model.isBusy || !TeleportProfileModel.isValidOneTimeCode(otp))
            } else {
                Button("Continue") {
                    model.registerSecureEnclaveCredential(name: name)
                    otp = ""
                }
                .accessibilityIdentifier("vvterm.teleport.credential.continue")
                .disabled(!validName || model.isBusy)
            }
            if model.discovery?.webAuthnConfigured == true {
                Button("Use a passkey instead") {
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
            Button("Cancel setup") {
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
