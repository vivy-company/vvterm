import Foundation
import TeleportKit
import Testing
@testable import VVTerm

/// Signals that a queued operation has released its captured work. This avoids
/// timing assumptions when checking cancellation before the task first executes.
private final class TeleportOperationReleaseProbe: Sendable {
    let completion: CheckedContinuation<Void, Never>

    init(_ completion: CheckedContinuation<Void, Never>) {
        self.completion = completion
    }

    deinit { completion.resume() }
}

@MainActor
struct TeleportProfileModelTests {
    @Test(arguments: [false, true])
    func cancelledQueuedLoginDoesNotCreateBrowserOrApplyError(localMFA: Bool) async throws {
        let model = try makeModel()
        var factoryCalls = 0
        await withCheckedContinuation { completion in
            var probe: TeleportOperationReleaseProbe? = TeleportOperationReleaseProbe(completion)
            model.login(browser: makeBrowserMethod(localMFA: localMFA)) { [probe] _ in
                withExtendedLifetime(probe) { factoryCalls += 1 }
                throw TeleportError.transport("cancelled work must not execute")
            }
            model.cancel()
            probe = nil
        }

        #expect(factoryCalls == 0)
        #expect(model.operation == .idle)
        #expect(model.errorMessage == nil)
        #expect(model.summary == nil)
    }

    @Test(arguments: [false, true])
    func browserCreationFailureUsesRedactedMessage(localMFA: Bool) async throws {
        let model = try makeModel()
        let failure = TeleportError.transport("private callback token")
        await withCheckedContinuation { completion in
            var probe: TeleportOperationReleaseProbe? = TeleportOperationReleaseProbe(completion)
            model.login(browser: makeBrowserMethod(localMFA: localMFA)) { [probe] _ in
                withExtendedLifetime(probe) {}
                throw failure
            }
            probe = nil
        }

        #expect(model.operation == .idle)
        #expect(model.errorMessage == TeleportAccessError.message(for: failure))
        #expect(model.errorMessage?.contains("private callback token") == false)
    }

    private func makeModel() throws -> TeleportProfileModel {
        let keychain = KeychainStore(service: "test.teleport.model", backing: InMemoryKeychainStoreBacking())
        let service = TeleportAccessService(
            keychain: keychain,
            makeBrowserSession: { _, _ in
                preconditionFailure("These tests supply a browser factory to the model")
            },
            didSignOut: { _ in }
        )
        return TeleportProfileModel(
            profile: try TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
            service: service
        )
    }

    private func makeBrowserMethod(localMFA: Bool) -> TeleportProfileModel.BrowserLogin {
        if localMFA { return .localMFA(password: "private password") }
        return .sso(TeleportConnector(kind: .oidc, id: "test", displayName: "Test"))
    }
}
