import SwiftUI
import TeleportKit

/// The window belongs to this sign-in, including when another app window is open.
struct TeleportSignInButton: View {
    let service: TeleportAccessService
    let model: TeleportProfileModel
    @State private var presentationWindow = TeleportPresentationWindow()

    var body: some View {
        Button("Sign in", action: signIn)
            .accessibilityIdentifier("vvterm.teleport.signIn")
            .background {
                TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func signIn() {
        let window = presentationWindow
        let service = service
        model.signIn { onCancel in
            guard let anchor = window.value else {
                throw TeleportError.transport("browser presentation window")
            }
            return service.makeBrowserSession(anchor, onCancel)
        }
    }
}
