import AuthenticationServices
import Foundation
import TeleportKit

/// The package owns the loopback response. This object keeps the system browser
/// open until the login finishes or the user cancels it.
@MainActor
final class TeleportAuthenticationBrowserSession: NSObject, TeleportBrowserSession {
    private enum State {
        case ready(PresentationContext)
        case running(ASWebAuthenticationSession, PresentationContext)
        case closed
    }

    @MainActor
    private final class PresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor
        }
    }

    private let onCancel: @MainActor @Sendable () -> Void
    private var state: State

    init(anchor: ASPresentationAnchor, onCancel: @escaping @MainActor @Sendable () -> Void) {
        self.onCancel = onCancel
        state = .ready(PresentationContext(anchor: anchor))
    }

    func open(_ url: URL) async throws {
        try Task.checkCancellation()
        guard case .ready(let context) = state else {
            throw TeleportError.invalidConfiguration("browser session has already started")
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, case .running = state else { return }
                state = .closed
                onCancel()
            }
        }
        session.presentationContextProvider = context
        state = .running(session, context)
        guard session.start() else {
            state = .closed
            throw TeleportError.transport("browser could not start")
        }
    }

    func cancel() {
        let previous = state
        state = .closed
        if case .running(let session, _) = previous {
            session.cancel()
        }
    }
}
