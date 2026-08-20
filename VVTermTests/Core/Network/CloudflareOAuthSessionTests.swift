import Foundation
import Testing
@testable import VVTerm

@MainActor
struct CloudflareOAuthSessionTests {
    @Test
    func restartCancelsPreviousSessionAndRejectsItsLateCompletion() async throws {
        let sessions = CloudflareOAuthSessionStore()
        let subject = CloudflareWebAuthenticationSessionActor(
            makeSession: { url, completion in
                sessions.makeSession(url: url, completion: completion)
            }
        )

        try await subject.start(url: URL(string: "https://example.com/first")!)
        try await subject.start(url: URL(string: "https://example.com/second")!)

        #expect(sessions.items.count == 2)
        #expect(sessions.items[0].cancelCount == 1)

        sessions.items[1].complete(didCancel: true)
        #expect(await waitUntil { await subject.didCancelLogin() })

        sessions.items[0].complete(didCancel: false)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(await subject.didCancelLogin())
    }

    @Test
    func stopCancelsOnlyTheActiveSession() async throws {
        let sessions = CloudflareOAuthSessionStore()
        let subject = CloudflareWebAuthenticationSessionActor(
            makeSession: { url, completion in
                sessions.makeSession(url: url, completion: completion)
            }
        )

        try await subject.start(url: URL(string: "https://example.com/login")!)
        await subject.stop()
        await subject.stop()

        #expect(sessions.items.count == 1)
        #expect(sessions.items[0].cancelCount == 1)
        #expect(!(await subject.didCancelLogin()))
    }

    @Test
    func failedStartCanBeRetried() async throws {
        let sessions = CloudflareOAuthSessionStore(nextStartResult: false)
        let subject = CloudflareWebAuthenticationSessionActor(
            makeSession: { url, completion in
                sessions.makeSession(url: url, completion: completion)
            }
        )

        await #expect(throws: (any Error).self) {
            try await subject.start(url: URL(string: "https://example.com/failure")!)
        }

        sessions.nextStartResult = true
        try await subject.start(url: URL(string: "https://example.com/retry")!)

        #expect(sessions.items.count == 2)
        #expect(sessions.items[1].startCount == 1)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class CloudflareOAuthSessionStore {
    var nextStartResult: Bool
    private(set) var items: [CloudflareOAuthSessionStub] = []

    init(nextStartResult: Bool = true) {
        self.nextStartResult = nextStartResult
    }

    func makeSession(
        url: URL,
        completion: @escaping @Sendable (Bool) -> Void
    ) -> CloudflareOAuthSessionStub {
        let session = CloudflareOAuthSessionStub(
            url: url,
            startResult: nextStartResult,
            completion: completion
        )
        items.append(session)
        return session
    }
}

@MainActor
private final class CloudflareOAuthSessionStub: CloudflareWebAuthenticationSessionRunning {
    let url: URL
    private let startResult: Bool
    private let completion: @Sendable (Bool) -> Void
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(
        url: URL,
        startResult: Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        self.url = url
        self.startResult = startResult
        self.completion = completion
    }

    func start() -> Bool {
        startCount += 1
        return startResult
    }

    func cancel() {
        cancelCount += 1
    }

    func complete(didCancel: Bool) {
        completion(didCancel)
    }
}
