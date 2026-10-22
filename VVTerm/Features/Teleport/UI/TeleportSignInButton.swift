import SwiftUI
import TeleportKit

/// The window belongs to this sign-in, including when another app window is open.
struct TeleportSignInButton: View {
    let service: TeleportAccessService
    let model: TeleportProfileModel
    var startsAutomatically = false
    @State private var presentationWindow = TeleportPresentationWindow()
    @State private var didStartAutomatically = false

    var body: some View {
        Button("Sign in", action: signIn)
            .accessibilityIdentifier("vvterm.teleport.signIn")
            .background {
                TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task {
                guard startsAutomatically, !didStartAutomatically else { return }
                didStartAutomatically = true
                signIn()
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
