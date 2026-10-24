import Combine
import Foundation
import TeleportKit
import Testing
@testable import VVTerm

/// Waits until a cancelled queued operation releases its captured work.
private final class TeleportOperationReleaseProbe: Sendable {
    let completion: CheckedContinuation<Void, Never>

    init(_ completion: CheckedContinuation<Void, Never>) {
        self.completion = completion
    }

    deinit { completion.resume() }
}

@MainActor
struct TeleportProfileModelTests {
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

    @Test
    func cancelledQueuedSignInDoesNotCreateBrowserOrApplyError() async throws {
        let model = try makeModel()
        var factoryCalls = 0
        await withCheckedContinuation { completion in
            var probe: TeleportOperationReleaseProbe? = TeleportOperationReleaseProbe(completion)
            model.signIn { [probe] _ in
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

    @Test
    func cancelledQueuedRemovalDoesNotApplyAnError() async throws {
        let model = try makeModel()
        model.deleteSecureEnclaveCredential()
        model.cancel()
        await Task.yield()
        #expect(model.operation == .idle)
        #expect(model.errorMessage == nil)
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
}
