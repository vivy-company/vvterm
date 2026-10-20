import SwiftUI
import TeleportKit

/// Each sign-in button supplies its own window, even if other form rows move off screen.
struct TeleportBrowserSignInButton: View {
    let method: TeleportProfileModel.BrowserLogin
    let service: TeleportAccessService
    let model: TeleportProfileModel
    let onStart: () -> Void
    @State private var presentationWindow = TeleportPresentationWindow()

    var body: some View {
        Button {
            onStart()
            let window = presentationWindow
            let service = service
            model.login(browser: method) { onCancel in
                guard let anchor = window.value else {
                    throw TeleportError.transport("browser presentation window")
                }
                return service.makeBrowserSession(anchor, onCancel)
            }
        } label: {
            switch method {
            case .localMFA:
                Text("Approve with a passkey or security key")
            case .sso(let connector):
                Text("Sign in with \(connector.displayName)")
            }
        }
        .background {
            TeleportPresentationWindowReader(presentationWindow: presentationWindow)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
