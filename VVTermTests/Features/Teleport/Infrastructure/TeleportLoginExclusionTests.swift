import Foundation
import TeleportKit
import Testing
@testable import VVTerm

private enum TeleportLoginTestStop: Error { case stopped }

/// Pauses an operation without network work and signals its entry without sleeps.
private actor TeleportLoginPause {
    private enum State {
        case idle
        case paused(CheckedContinuation<Void, Never>)
        case released
    }

    private var state = State.idle
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            guard case .idle = state else { continuation.resume(); return }
            state = .paused(continuation)
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }

    func waitUntilEntered() async {
        guard case .idle = state else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        let previous = state
        state = .released
        if case .paused(let continuation) = previous { continuation.resume() }
    }
}

@MainActor
struct TeleportLoginExclusionTests {
    @Test
    func canonicalProfileCannotStartASecondLoginAndCanRetryAfterCompletion() async throws {
        let keychain = KeychainStore(service: "test.teleport.login", backing: InMemoryKeychainStoreBacking())
        let service = makeService(keychain: keychain)
        let profile = try TeleportProfileConfiguration(proxyURL: "https://PROXY.example.test:443/", account: "alice")
        let equivalent = try TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: " alice ", connectorID: "other")
        #expect(profile.identifier == equivalent.identifier)
        let pause = TeleportLoginPause()
        let first = Task {
            try await service.performLogin(profile: profile) { _ in
                await pause.pause()
                throw TeleportLoginTestStop.stopped
            }
        }
        defer {
            first.cancel()
            Task { await pause.release() }
        }
        await pause.waitUntilEntered()

        do {
            _ = try await service.performLogin(profile: equivalent) { _ in
                throw TeleportLoginTestStop.stopped
            }
            Issue.record("A second login must not start for the same canonical profile")
        } catch TeleportAccessError.loginInProgress {
            #expect(TeleportAccessError.message(for: TeleportAccessError.loginInProgress)
                == String(localized: "This Teleport profile is signing in. Finish or cancel it, then try again.", bundle: .main))
        } catch {
            Issue.record("The second login ran instead of returning the fixed busy error: \(error)")
        }

        await pause.release()
        _ = await first.result
        do {
            _ = try await service.performLogin(profile: profile) { _ in
                throw TeleportLoginTestStop.stopped
            }
            Issue.record("The test operation must stop")
        } catch TeleportLoginTestStop.stopped {
            // The new operation ran, so the completed attempt released its state.
        }
    }

    @Test
    func signOutTakesOverAndOldCompletionCannotReleaseANewerLogin() async throws {
        let keychain = KeychainStore(service: "test.teleport.login", backing: InMemoryKeychainStoreBacking())
        let service = makeService(keychain: keychain)
        let profile = try TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice")
        try keychain.set(Data("record to remove without decoding".utf8), forKey: profile.identifier, scope: .deviceOnly)
        let oldPause = TeleportLoginPause()
        let old = Task {
            try await service.performLogin(profile: profile) { _ in
                await oldPause.pause()
                throw TeleportLoginTestStop.stopped
            }
        }
        defer {
            old.cancel()
            Task { await oldPause.release() }
        }
        await oldPause.waitUntilEntered()
        try await service.signOut(profile: profile)
        #expect(try keychain.get(profile.identifier, scope: .deviceOnly) == nil)

        let currentPause = TeleportLoginPause()
        let current = Task {
            try await service.performLogin(profile: profile) { _ in
                await currentPause.pause()
                throw TeleportLoginTestStop.stopped
            }
        }
        defer {
            current.cancel()
            Task { await currentPause.release() }
        }
        await currentPause.waitUntilEntered()
        await oldPause.release()
        _ = await old.result
        do {
            _ = try await service.performLogin(profile: profile) { _ in
                throw TeleportLoginTestStop.stopped
            }
            Issue.record("An old completion must not release the newer active login")
        } catch TeleportAccessError.loginInProgress {
        } catch {
            Issue.record("The newer login lost its exclusive state: \(error)")
        }
        await currentPause.release()
        _ = await current.result
    }

    private func makeService(keychain: KeychainStore) -> TeleportAccessService {
        TeleportAccessService(
            keychain: keychain,
            makeBrowserSession: { _, _ in preconditionFailure("These tests do not open a browser") },
            didSignOut: { _ in }
        )
    }
}
