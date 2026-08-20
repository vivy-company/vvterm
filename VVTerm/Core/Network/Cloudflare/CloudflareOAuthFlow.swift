import Foundation
import AuthenticationServices
import Cloudflared
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CloudflareOAuthFlow: OAuthFlow {
    private let flow: TransferOAuthFlow

    init(userAgent: String = "VVTerm") {
        self.flow = TransferOAuthFlow(
            webSession: CloudflareWebAuthenticationSessionActor(),
            userAgent: userAgent
        )
    }

    func fetchToken(
        teamDomain: String,
        appDomain: String,
        callbackScheme: String,
        hostname: String
    ) async throws -> String {
        try await flow.fetchToken(
            teamDomain: teamDomain,
            appDomain: appDomain,
            callbackScheme: callbackScheme,
            hostname: hostname
        )
    }
}

actor CloudflareWebAuthenticationSessionActor: OAuthWebSession {
    private struct ActiveSession {
        let generation: UUID
        let session: any CloudflareWebAuthenticationSessionRunning
    }

    private let makeSession: CloudflareWebAuthenticationSessionFactory
    private var activeSession: ActiveSession?
    private var userDidCancel = false

    init(
        makeSession: @escaping CloudflareWebAuthenticationSessionFactory = { url, completion in
            CloudflareWebAuthenticationSession(url: url, completion: completion)
        }
    ) {
        self.makeSession = makeSession
    }

    func start(url: URL) async throws {
        let generation = UUID()
        userDidCancel = false

        let session = await makeSession(url) { [weak self] didCancel in
            Task { [weak self] in
                await self?.handleCompletion(generation: generation, didCancel: didCancel)
            }
        }

        let previousSession = activeSession
        activeSession = ActiveSession(generation: generation, session: session)
        await previousSession?.session.cancel()

        guard isActive(session, generation: generation) else {
            await session.cancel()
            return
        }

        let didStart = await session.start()
        guard isActive(session, generation: generation) else {
            await session.cancel()
            return
        }

        if !didStart {
            activeSession = nil
            throw Failure.auth("Failed to start Cloudflare login session")
        }
    }

    func stop() async {
        let session = activeSession?.session
        activeSession = nil
        await session?.cancel()
    }

    func didCancelLogin() async -> Bool {
        userDidCancel
    }

    private func handleCompletion(generation: UUID, didCancel: Bool) {
        guard activeSession?.generation == generation else { return }
        activeSession = nil
        userDidCancel = didCancel
    }

    private func isActive(
        _ session: any CloudflareWebAuthenticationSessionRunning,
        generation: UUID
    ) -> Bool {
        guard let activeSession else { return false }
        return activeSession.generation == generation && activeSession.session === session
    }
}

@MainActor
protocol CloudflareWebAuthenticationSessionRunning: AnyObject, Sendable {
    func start() -> Bool
    func cancel()
}

typealias CloudflareWebAuthenticationSessionFactory = @MainActor @Sendable (
    URL,
    @escaping @Sendable (Bool) -> Void
) -> any CloudflareWebAuthenticationSessionRunning

@MainActor
private final class CloudflareWebAuthenticationSession: CloudflareWebAuthenticationSessionRunning {
    private let session: ASWebAuthenticationSession
    private let presentationContextProvider = CloudflarePresentationContextProvider()

    init(url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        self.session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
            completion(error != nil)
        }
        session.presentationContextProvider = presentationContextProvider
        session.prefersEphemeralWebBrowserSession = false
    }

    func start() -> Bool {
        session.start()
    }

    func cancel() {
        session.cancel()
    }
}

@MainActor
private final class CloudflarePresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        return scenes.first?.windows.first ?? ASPresentationAnchor()
        #elseif os(macOS)
        if let keyWindow = NSApplication.shared.keyWindow {
            return keyWindow
        }
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
