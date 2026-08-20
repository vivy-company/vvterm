import Foundation
import Testing
@testable import VVTerm

struct CloudKitSyncStateTests {
    @Test
    func operationFailureRemainsVisibleUntilAnotherOperationStarts() {
        var state = CloudKitSyncState.available
        let failedOperation = UUID()

        let didBeginFailedOperation = state.beginOperation(failedOperation)
        #expect(didBeginFailedOperation)
        state.completeOperation(failedOperation, with: .failure("Save failed"))

        #expect(state.status == .error("Save failed"))
        #expect(state.isAvailable)

        let retryOperation = UUID()
        let didBeginRetryOperation = state.beginOperation(retryOperation)
        #expect(didBeginRetryOperation)
        #expect(state.status == .syncing)

        state.completeOperation(retryOperation, with: .success)
        #expect(state.status == .idle)
    }

    @Test
    func staleFailureCannotOverwriteNewerSuccessfulOperation() {
        var state = CloudKitSyncState.available
        let olderOperation = UUID()
        let newerOperation = UUID()

        let didBeginOlderOperation = state.beginOperation(olderOperation)
        let didBeginNewerOperation = state.beginOperation(newerOperation)
        #expect(didBeginOlderOperation)
        #expect(didBeginNewerOperation)

        state.completeOperation(newerOperation, with: .success)
        #expect(state.status == .syncing)

        state.completeOperation(olderOperation, with: .failure("Stale failure"))
        #expect(state.status == .idle)
    }

    @Test
    func environmentalStateRejectsStaleOperationCompletion() {
        var state = CloudKitSyncState.available
        let operation = UUID()

        let didBeginOperation = state.beginOperation(operation)
        #expect(didBeginOperation)
        state.markDisabled()
        state.completeOperation(operation, with: .failure("Stale failure"))

        #expect(state.status == .disabled)
        #expect(!state.isAvailable)
    }

    @Test
    func overlappingOperationsRemainSyncingUntilEveryOperationCompletes() {
        var state = CloudKitSyncState.available
        let firstOperation = UUID()
        let secondOperation = UUID()

        let didBeginFirstOperation = state.beginOperation(firstOperation)
        let didBeginSecondOperation = state.beginOperation(secondOperation)
        #expect(didBeginFirstOperation)
        #expect(didBeginSecondOperation)

        state.completeOperation(firstOperation, with: .success)
        #expect(state.status == .syncing)

        state.completeOperation(secondOperation, with: .success)
        #expect(state.status == .idle)
    }
}
