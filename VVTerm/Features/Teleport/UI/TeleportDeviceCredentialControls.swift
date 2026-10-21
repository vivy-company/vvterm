import SwiftUI
import TeleportKit

struct TeleportDeviceCredentialControls: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel

    private enum Presentation { case menu, setup, removal }
    @State private var presentation: Presentation?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { presentation != nil },
            set: { expanded in
                if expanded {
                    if presentation == nil { presentation = .menu }
                } else if presentation != .setup && !model.isBusy {
                    presentation = nil
                }
            }
        )) {
            if presentation == .setup {
                TeleportDeviceCredentialSetup(service: service, model: model) { presentation = .menu }
            } else {
                Text("Use Face ID or Touch ID instead of a code.").foregroundStyle(.secondary)
                Button(model.canRegisterCredential ? "Set up this device" : "Sign in before setup") { presentation = .setup }
                    .accessibilityIdentifier("vvterm.teleport.credential.setup")
                    .disabled(model.isBusy || !model.canRegisterCredential)
                Button("Remove from this device…", role: .destructive) { presentation = .removal }
                    .accessibilityIdentifier("vvterm.teleport.credential.remove")
                    .disabled(model.isBusy)
            }
            if let failure = model.failure, failure.operation.isCredentialManagement,
               failure.operation != .registeringCredential || presentation == .setup {
                Text(failure.message).foregroundStyle(.red)
            }
            if model.isBusy && model.operation.isCredentialManagement {
                ProgressView(model.operation == .registeringCredential ? "Setting up…" : "Removing…")
            }
            if model.credentialResult == .registered {
                Text("Device added.").foregroundStyle(.secondary)
            } else if model.credentialResult == .deleted {
                Text("Device removed.").foregroundStyle(.secondary)
            }
        } label: {
            Text("Teleport verification")
                .accessibilityIdentifier("vvterm.teleport.credential.controls")
        }
        .confirmationDialog("Remove local key?", isPresented: Binding(
            get: { presentation == .removal },
            set: { if !$0 && presentation == .removal { presentation = .menu } }
        )) {
            Button("Remove local key", role: .destructive) { model.deleteSecureEnclaveCredential() }
        } message: {
            Text("Access stays valid. Keep another sign-in method. Remove the device entry in Teleport before setup again.")
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
