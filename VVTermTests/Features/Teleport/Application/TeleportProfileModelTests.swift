import Combine
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
    @Test(arguments: ["12345", "123456789", "12a456", "１２３４５６", " 123456", "123456\n"])
    func invalidSetupCodeDoesNotReachCredentialStorage(code: String) async throws {
        #expect(!TeleportProfileModel.isValidOneTimeCode(code))
        let model = try makeModel()
        model.registerSecureEnclaveCredential(name: "Test device", otp: code)
        for await operation in model.$operation.values {
            if operation == .idle { break }
        }
        #expect(model.errorMessage == TeleportAccessError.message(for: TeleportAccessError.deviceSetupCodeRequired))
        #expect(model.failure?.operation == .registeringCredential)
        #expect(model.credentialResult == nil)
    }

    @Test(arguments: ["123456", "1234567", "12345678"])
    func setupCodeAcceptsOnlySupportedASCIIDigitLengths(code: String) {
        #expect(TeleportProfileModel.isValidOneTimeCode(code))
    }

    @Test
    func emptySetupCodeIsLeftToTheLibraryPolicyCheck() async throws {
        let model = try makeModel()
        model.registerSecureEnclaveCredential(name: "Test device")
        for await operation in model.$operation.values {
            if operation == .idle { break }
        }
        // The empty test store stops registration at identity lookup, after app input checks.
        #expect(model.errorMessage == TeleportAccessError.message(for: TeleportError.authenticationRequired))
        #expect(model.credentialResult == nil)
    }

    @Test
    func onlyOneCompleteInitialResultCanFillAnEmptyNode() throws {
        let first = try TeleportNode(id: "first", name: "First", clusterName: "cluster")
        let second = try TeleportNode(id: "second", name: "Second", clusterName: "cluster")
        let single = [first]
        #expect(TeleportProfileModel.singleNode(in: single, hasMore: false, currentNodeID: "", isFirstPage: true) == first)
        #expect(TeleportProfileModel.singleNode(in: single, hasMore: false, currentNodeID: "saved", isFirstPage: true) == nil)
        #expect(TeleportProfileModel.singleNode(in: single, hasMore: false, currentNodeID: "", isFirstPage: false) == nil)
        #expect(TeleportProfileModel.singleNode(
            in: [first], hasMore: true, currentNodeID: "", isFirstPage: true
        ) == nil)
        #expect(TeleportProfileModel.singleNode(
            in: [first, second], hasMore: false, currentNodeID: "", isFirstPage: true
        ) == nil)
        #expect(TeleportProfileModel.singleNode(
            in: [], hasMore: false, currentNodeID: "", isFirstPage: true
        ) == nil)
    }

    enum DeviceOperation: CaseIterable { case login, registration, removal }

    @Test
    func setupCancelDoesNotCancelSignOutInAnotherSection() throws {
        let model = try makeModel()
        model.signOut()
        model.cancelCredentialSetup()
        #expect(model.operation == .signingOut)
        model.cancel()

        model.registerSecureEnclaveCredential(name: "Test device")
        model.cancelCredentialSetup()
        #expect(model.operation == .idle)
    }

    @Test(arguments: DeviceOperation.allCases)
    func cancelledQueuedDeviceOperationDoesNotApplyAResult(operation: DeviceOperation) async throws {
        let model = try makeModel()
        switch operation {
        case .login: model.loginWithSecureEnclave(password: "private password")
        case .registration: model.registerSecureEnclaveCredential(name: "Test device", otp: "123456")
        case .removal: model.deleteSecureEnclaveCredential()
        }
        model.cancel()
        // The new task must check cancellation before reaching the service.
        await Task.yield()
        #expect(model.operation == .idle)
        #expect(model.errorMessage == nil)
        #expect(model.credentialResult == nil)
        #expect(model.canRegisterCredential == false)
    }

    @Test
    func cancelledQueuedSetupDoesNotCreateBrowser() async throws {
        let model = try makeModel()
        var factoryCalls = 0
        await withCheckedContinuation { completion in
            var probe: TeleportOperationReleaseProbe? = TeleportOperationReleaseProbe(completion)
            model.registerSecureEnclaveCredential(name: "Test device") { [probe] _ in
                withExtendedLifetime(probe) { factoryCalls += 1 }
                throw TeleportError.transport("cancelled work must not execute")
            }
            model.cancel()
            probe = nil
        }
        #expect(factoryCalls == 0)
        #expect(model.operation == .idle)
        #expect(model.errorMessage == nil)
        #expect(model.credentialResult == nil)
    }

    @Test
    func setupBrowserFailureUsesSafeRecoveryText() async throws {
        let model = try makeModel()
        let failure = TeleportError.transport("private callback token")
        await withCheckedContinuation { completion in
            var probe: TeleportOperationReleaseProbe? = TeleportOperationReleaseProbe(completion)
            model.registerSecureEnclaveCredential(name: "Test device") { [probe] _ in
                withExtendedLifetime(probe) {}
                throw failure
            }
            probe = nil
        }
        #expect(model.operation == .idle)
        #expect(model.errorMessage == TeleportAccessError.message(for: failure))
        #expect(model.failure?.operation.isDeviceAuthentication == true)
        #expect(model.errorMessage?.contains("private callback token") == false)
        #expect(model.credentialResult == nil)
    }

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
