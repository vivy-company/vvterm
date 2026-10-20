import SwiftUI
import TeleportKit

/// Each sign-in button supplies its own window, even if other form rows move off screen.
struct TeleportBrowserSignInButton: View {
    let connector: TeleportConnector
    let service: TeleportAccessService
    let model: TeleportProfileModel
    let onStart: () -> Void
    @State private var presentationWindow = TeleportPresentationWindow()

    var body: some View {
        Button {
            onStart()
            let window = presentationWindow
            let service = service
            model.login(connector: connector) { onCancel in
                guard let anchor = window.value else {
                    throw TeleportError.transport("browser presentation window")
                }
                return service.makeBrowserSession(anchor, onCancel)
            }
        } label: {
            Text("Sign in with \(connector.displayName)")
        }
        .background {
            TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
