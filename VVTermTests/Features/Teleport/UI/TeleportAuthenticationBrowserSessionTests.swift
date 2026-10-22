import AuthenticationServices
import Foundation
import TeleportKit
import Testing
@testable import VVTerm

@MainActor
struct TeleportAuthenticationBrowserSessionTests {
    @Test
    func deviceApprovalReplacesLoginAndIgnoresOldCancellation() async throws {
        let sessions = BrowserSessions()
        var cancellations = 0
        let subject = TeleportAuthenticationBrowserSession(anchor: ASPresentationAnchor()) { cancellations += 1 }
        try subject.open(URL(string: "https://proxy.example/web/headless/login")!, makeSession: sessions.make)
        try subject.open(URL(string: "https://proxy.example/web/mfa/browser/approval")!, makeSession: sessions.make)
        #expect(sessions.items.count == 2)
        #expect(sessions.items[0].cancelCount == 1)
        #expect(sessions.items[1].startCount == 1)
        #expect(sessions.items[1].presentationContextProvider != nil)

        sessions.items[0].completeCancellation()
        await drainCallbacks()
        #expect(cancellations == 0)

        sessions.items[1].completeCancellation()
        #expect(await waitUntil { cancellations == 1 })
        sessions.items[1].completeCancellation()
        await drainCallbacks()
        #expect(cancellations == 1)
    }

    @Test
    func programmaticStopCancelsOnlyTheCurrentSessionWithoutReportingUserCancellation() async throws {
        let sessions = BrowserSessions()
        var cancellations = 0
        let subject = TeleportAuthenticationBrowserSession(anchor: ASPresentationAnchor()) { cancellations += 1 }
        try subject.open(URL(string: "https://proxy.example/first")!, makeSession: sessions.make)
        try subject.open(URL(string: "https://proxy.example/second")!, makeSession: sessions.make)
        subject.cancel()
        subject.cancel()
        await drainCallbacks()
        #expect(sessions.items[0].cancelCount == 1)
        #expect(sessions.items[1].cancelCount == 1)
        #expect(cancellations == 0)
        #expect(throws: TeleportError.invalidConfiguration("browser session is closed")) {
            try subject.open(URL(string: "https://proxy.example/third")!, makeSession: sessions.make)
        }
        #expect(sessions.items.count == 2)
    }

    @Test
    func failedReplacementStartReportsAnErrorAndRejectsItsLateCallback() async throws {
        let sessions = BrowserSessions()
        var cancellations = 0
        let subject = TeleportAuthenticationBrowserSession(anchor: ASPresentationAnchor()) { cancellations += 1 }
        try subject.open(URL(string: "https://proxy.example/first")!, makeSession: sessions.make)
        sessions.startResult = false
        #expect(throws: TeleportError.transport("browser could not start")) {
            try subject.open(URL(string: "https://proxy.example/second")!, makeSession: sessions.make)
        }
        sessions.items[1].completeCancellation()
        await drainCallbacks()
        #expect(sessions.items[0].cancelCount == 1)
        #expect(sessions.items[1].startCount == 1)
        #expect(cancellations == 0)
    }

    private func drainCallbacks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class BrowserSessions {
    var startResult = true
    private(set) var items: [BrowserSessionStub] = []

    func make(url: URL, completion: @escaping ASWebAuthenticationSession.CompletionHandler) -> ASWebAuthenticationSession {
        let session = BrowserSessionStub(url: url, startResult: startResult, completion: completion)
        items.append(session)
        return session
    }
}

@MainActor
private final class BrowserSessionStub: ASWebAuthenticationSession, @unchecked Sendable {
    private let completion: ASWebAuthenticationSession.CompletionHandler
    private let startResult: Bool
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(url: URL, startResult: Bool, completion: @escaping ASWebAuthenticationSession.CompletionHandler) {
        self.completion = completion
        self.startResult = startResult
        super.init(url: url, callbackURLScheme: nil, completionHandler: completion)
    }

    nonisolated override func start() -> Bool {
        // The native override is not actor-isolated; every test call must use the adapter's main actor.
        MainActor.assumeIsolated {
            startCount += 1
            return startResult
        }
    }

    nonisolated override func cancel() {
        MainActor.assumeIsolated {
            cancelCount += 1
            completeCancellation()
        }
    }

    func completeCancellation() {
        completion(nil, NSError(domain: ASWebAuthenticationSessionErrorDomain, code: 1))
    }
}
