import AuthenticationServices
import Foundation
import TeleportKit

/// The package receives authentication results. This object owns the system browser
/// through login and device approval, until the operation finishes or the user cancels.
@MainActor
final class TeleportAuthenticationBrowserSession: NSObject, TeleportBrowserSession {
    private enum State {
        case ready(PresentationContext)
        case active(ASWebAuthenticationSession, PresentationContext)
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
        try await open(url, makeSession: { url, completion in
            ASWebAuthenticationSession(url: url, callbackURLScheme: nil, completionHandler: completion)
        })
    }

    func open(
        _ url: URL,
        makeSession: @MainActor (URL, @escaping ASWebAuthenticationSession.CompletionHandler) -> ASWebAuthenticationSession,
        readinessTimeout: Duration = .seconds(5),
        waitForReadiness: @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(50))
        }
    ) async throws {
        try Task.checkCancellation()
        let context: PresentationContext
        switch state {
        case .ready(let readyContext):
            context = readyContext
        case .active(let previous, let previousContext):
            context = PresentationContext(anchor: previousContext.anchor)
            // Invalidate the old callback before programmatic cancellation can complete it.
            state = .ready(context)
            previous.cancel()
        case .closed:
            throw TeleportError.invalidConfiguration("browser session is closed")
        }
        let session = makeSession(url) { [weak self, weak context] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self, weak context] in
                guard let self, let context, case .active(_, let currentContext) = state,
                      currentContext === context else { return }
                state = .closed
                onCancel()
            }
        }
        session.presentationContextProvider = context
        state = .active(session, context)
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: readinessTimeout)
            // cancel() starts dismissal but has no completion contract. Check
            // Apple's readiness property before the one permitted start() call.
            while true {
                try Task.checkCancellation()
                guard isCurrent(context) else { throw CancellationError() }
                guard clock.now < deadline else {
                    throw TeleportError.transport("browser could not start")
                }
                if session.canStart { break }
                try await waitForReadiness()
            }
            guard session.start() else {
                throw TeleportError.transport("browser could not start")
            }
        } catch {
            if isCurrent(context) {
                state = .closed
                session.cancel()
            }
            throw error
        }
    }

    func cancel() {
        let previous = state
        state = .closed
        if case .active(let session, _) = previous {
            session.cancel()
        }
    }

    private func isCurrent(_ context: PresentationContext) -> Bool {
        guard case .active(_, let current) = state else { return false }
        return current === context
    }
}
