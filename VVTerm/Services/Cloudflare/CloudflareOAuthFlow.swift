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
            webSession: CloudflareWebAuthenticationSessionActor.shared,
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
    static let shared = CloudflareWebAuthenticationSessionActor()

    private var currentSession: ASWebAuthenticationSession?
    private var ignoreNextCompletion = false
    private var userDidCancel = false
    private var presentationContextProvider: CloudflarePresentationContextProvider?

    func start(url: URL) async throws {
        if currentSession != nil {
            await resetForRestart()
        }

        userDidCancel = false
        ignoreNextCompletion = false

        let provider = await ensurePresentationContextProvider()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task {
                await self?.handleCompletion(error: error)
            }
        }

        await MainActor.run {
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
        }

        currentSession = session
        let didStart = await MainActor.run { session.start() }
        if !didStart {
            currentSession = nil
            throw Failure.auth("Failed to start Cloudflare login session")
        }
    }

    func stop() async {
        guard let session = currentSession else { return }
        ignoreNextCompletion = true
        await MainActor.run {
            session.cancel()
        }
        currentSession = nil
    }

    func didCancelLogin() async -> Bool {
        userDidCancel
    }

    private func resetForRestart() async {
        ignoreNextCompletion = true
        if let session = currentSession {
            await MainActor.run {
                session.cancel()
            }
        }
        currentSession = nil
        userDidCancel = false
    }

    private func ensurePresentationContextProvider() async -> CloudflarePresentationContextProvider {
        if let presentationContextProvider {
            return presentationContextProvider
        }
        let provider = await MainActor.run {
            CloudflarePresentationContextProvider()
        }
        presentationContextProvider = provider
        return provider
    }

    private func handleCompletion(error: Error?) {
        defer {
            currentSession = nil
        }

        if ignoreNextCompletion {
            ignoreNextCompletion = false
            return
        }

        if let authError = error as? ASWebAuthenticationSessionError,
           authError.code == .canceledLogin {
            userDidCancel = true
        } else if error != nil {
            userDidCancel = true
        }
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
