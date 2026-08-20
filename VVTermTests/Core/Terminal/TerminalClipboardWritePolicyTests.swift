import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalClipboardWritePolicyTests {
    @Test
    func localCopyWritesImmediately() {
        #expect(
            TerminalClipboardWritePolicy.action(requiresConfirmation: false)
                == .writeImmediately
        )
    }

    @Test
    func remoteRequestedWriteRequiresConfirmation() {
        #expect(
            TerminalClipboardWritePolicy.action(requiresConfirmation: true)
                == .requestConfirmation
        )
    }

    @Test
    func remoteClipboardReadDefaultsToAsk() {
        let suiteName = "TerminalClipboardWritePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TerminalRemoteClipboardReadPolicy.resolved(defaults: defaults) == .ask)
        defaults.set("invalid", forKey: TerminalRemoteClipboardReadPolicy.userDefaultsKey)
        #expect(TerminalRemoteClipboardReadPolicy.resolved(defaults: defaults) == .ask)
    }

    @Test
    func confirmationQueuePresentsAndCompletesRequestsInOrderOnce() throws {
        let queue = TerminalClipboardConfirmationQueue()
        var completions: [(String, TerminalClipboardConfirmationDecision)] = []
        queue.enqueue(kind: .remoteRead) { completions.append(("read", $0)) }
        queue.enqueue(kind: .remoteWrite) { completions.append(("write", $0)) }

        let first = try #require(queue.requestToPresent)
        #expect(first.kind == .remoteRead)
        #expect(queue.resolve(id: first.id, decision: .allow))
        #expect(!queue.resolve(id: first.id, decision: .cancel))

        let second = try #require(queue.requestToPresent)
        #expect(second.kind == .remoteWrite)
        #expect(queue.resolve(id: second.id, decision: .cancel))
        #expect(completions.map(\.0) == ["read", "write"])
        #expect(completions.map(\.1) == [.allow, .cancel])
    }

    @Test
    func cancellingQueueCompletesEveryRequestOnce() throws {
        let queue = TerminalClipboardConfirmationQueue()
        var decisions: [TerminalClipboardConfirmationDecision] = []
        queue.enqueue(kind: .unsafePaste) { decisions.append($0) }
        queue.enqueue(kind: .remoteRead) { decisions.append($0) }
        let activeID = try #require(queue.requestToPresent?.id)

        queue.cancelAll()
        #expect(decisions == [.cancel, .cancel])
        #expect(!queue.resolve(id: activeID, decision: .allow))
        #expect(queue.requestToPresent?.id == nil)
    }

    @Test
    func confirmationQueueRejectsOverflowAndCompletesItOnce() {
        let queue = TerminalClipboardConfirmationQueue()
        var overflowDecisions: [TerminalClipboardConfirmationDecision] = []
        for _ in 0..<TerminalClipboardConfirmationQueue.maximumRequestCount {
            queue.enqueue(kind: .remoteRead) { _ in }
        }

        queue.enqueue(kind: .remoteRead) { overflowDecisions.append($0) }

        #expect(overflowDecisions == [.cancel])
    }

    @Test
    func repeatedRemoteWritesDoNotCreateAnAlertBacklog() throws {
        let queue = TerminalClipboardConfirmationQueue()
        var decisions: [TerminalClipboardConfirmationDecision] = []

        queue.enqueue(kind: .remoteWrite) { decisions.append($0) }
        let first = try #require(queue.requestToPresent)
        for _ in 0..<32 {
            queue.enqueue(kind: .remoteWrite) { decisions.append($0) }
        }

        #expect(decisions == Array(repeating: .cancel, count: 32))
        #expect(queue.requestToPresent?.id == first.id)
        #expect(queue.resolve(id: first.id, decision: .allow))
        #expect(decisions.last == .allow)
        #expect(queue.requestToPresent?.id == nil)
    }

    @Test
    func unavailablePresenterRetriesWithABoundThenCancels() {
        #expect(
            TerminalClipboardPresentationRetryPolicy.action(after: 0)
                == .retry(nextAttempt: 1)
        )
        #expect(
            TerminalClipboardPresentationRetryPolicy.action(
                after: TerminalClipboardPresentationRetryPolicy.maximumAttempts
            ) == .cancel
        )
    }
}
