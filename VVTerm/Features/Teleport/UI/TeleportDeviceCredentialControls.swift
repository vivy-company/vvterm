import SwiftUI
import TeleportKit

/// The library owns enrollment and key use. This view owns only form values and presentation.
struct TeleportDeviceCredentialControls: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel

    private enum Presentation: Equatable { case setup, removal }
    @State private var presentation: Presentation?
    @State private var presentationWindow = TeleportPresentationWindow()

    var body: some View {
        DisclosureGroup {
            Text("Your Teleport password is still required. Keep another sign-in method for recovery.")
                .foregroundStyle(.secondary)
            Button("Set up device credential…") { presentation = .setup }
                .accessibilityIdentifier("vvterm.teleport.credential.setup")
                .disabled(model.isBusy || !model.canRegisterCredential)
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
        .sheet(isPresented: Binding(
            get: { presentation == .setup },
            set: { if !$0 { presentation = nil } }
        )) {
            TeleportDeviceCredentialSetup(service: service, model: model, presentationWindow: presentationWindow)
        }
        .confirmationDialog("Remove this device's Teleport credential?", isPresented: Binding(
            get: { presentation == .removal },
            set: { if !$0 { presentation = nil } }
        )) {
            Button("Remove local credential", role: .destructive) {
                model.deleteSecureEnclaveCredential()
            }
        } message: {
            Text("Sign in another way, then remove the server entry in Teleport before setup again. Current access stays valid.")
        }
        .background {
            TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct TeleportDeviceCredentialSetup: View {
    let service: TeleportAccessService
    @ObservedObject var model: TeleportProfileModel
    let presentationWindow: TeleportPresentationWindow
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var otp = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device credential name", text: $name)
                        .accessibilityIdentifier("vvterm.teleport.credential.name")
                    SecureField("Fresh one-time code (if required)", text: $otp)
                    Button("Set up with one-time code") {
                        model.registerSecureEnclaveCredential(name: name, otp: otp)
                        otp = ""
                        dismiss()
                    }
                    .disabled(!validName)
                    if model.discovery?.webAuthnConfigured == true {
                        Button("Set up with browser approval") {
                            let window = presentationWindow
                            let service = service
                            model.registerSecureEnclaveCredential(name: name) { onCancel in
                                guard let anchor = window.value else {
                                    throw TeleportError.transport("browser presentation window")
                                }
                                return service.makeBrowserSession(anchor, onCancel)
                            }
                            otp = ""
                            dismiss()
                        }
                        .disabled(!validName)
                    }
                } footer: {
                    Text("Use a fresh code or an existing passkey or security key. Face ID or Touch ID protects the new key. It stays on this device, separate from SSH keys.")
                }
            }
            .navigationTitle("Set up Teleport credential")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { otp = ""; dismiss() }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 280)
        .onDisappear { otp = "" }
    }

    private var validName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 30
    }
}
