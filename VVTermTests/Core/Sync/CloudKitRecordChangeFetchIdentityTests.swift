import Foundation
import Testing
@testable import VVTerm

struct CloudKitRecordChangeFetchIdentityTests {
    @Test
    func desiredKeyIdentityIgnoresOrderAndDuplicates() {
        #expect(
            CloudKitRecordChangeFetchIdentity(
                forceFullFetch: false,
                desiredKeys: ["name", "host", "name"]
            )
                == CloudKitRecordChangeFetchIdentity(
                    forceFullFetch: false,
                    desiredKeys: ["host", "name"]
                )
        )
    }

    @Test
    func sameRequestCoalesces() throws {
        let request = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["host", "name"]
        )

        #expect(
            try CloudKitRecordChangeRequestPolicy.decision(
                for: request,
                inFlight: request
            ) == .coalesce
        )
    }

    @Test
    func canceledFetchWithNoWaitersRequiresTeardownBeforeReuse() {
        #expect(
            CloudKitRecordChangeRequestPolicy.requiresCancellationTeardown(
                activeWaiterCount: 0
            )
        )
        #expect(
            !CloudKitRecordChangeRequestPolicy.requiresCancellationTeardown(
                activeWaiterCount: 1
            )
        )
    }

    @Test
    func differentDesiredKeysAreRejectedWhileRequestIsInFlight() {
        let inFlight = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["name"]
        )
        let request = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["name", "host"]
        )

        do {
            _ = try CloudKitRecordChangeRequestPolicy.decision(
                for: request,
                inFlight: inFlight
            )
            Issue.record("Expected incompatible change-stream request")
        } catch {
            #expect(error as? CloudKitRecordChangeStreamError == .incompatibleRequestInFlight)
        }
    }

    @Test
    func differentFetchModesAreRejectedWhileRequestIsInFlight() {
        let inFlight = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: false,
            desiredKeys: ["host", "name"]
        )
        let request = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: true,
            desiredKeys: ["host", "name"]
        )

        do {
            _ = try CloudKitRecordChangeRequestPolicy.decision(
                for: request,
                inFlight: inFlight
            )
            Issue.record("Expected incompatible change-stream request")
        } catch {
            #expect(error as? CloudKitRecordChangeStreamError == .incompatibleRequestInFlight)
        }
    }

    @Test
    func checkpointPolicyAcceptsOnlyTheCurrentPendingCheckpoint() throws {
        let pending = CloudKitRecordChangeCheckpoint(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let stale = CloudKitRecordChangeCheckpoint(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )

        try CloudKitRecordChangeCheckpointPolicy.validate(pending, pending: pending)
        #expect(throws: CloudKitRecordChangeStreamError.invalidCheckpoint) {
            try CloudKitRecordChangeCheckpointPolicy.validate(stale, pending: pending)
        }
        #expect(throws: CloudKitRecordChangeStreamError.invalidCheckpoint) {
            try CloudKitRecordChangeCheckpointPolicy.validate(pending, pending: nil)
        }
    }

    @Test
    func operationCancellationCompletesOnceAndCancelsOperation() async {
        let completion = CloudKitOperationContinuation<Int>()
        let operation = CancellationCountingOperation()
        completion.install(operation)
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
            }
        }

        completion.cancel()
        completion.resume(returning: 42)
        completion.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(operation.cancellationCount == 1)
    }

    @Test
    func operationSuccessWinsExactlyOnceOverLateCancellation() async throws {
        let completion = CloudKitOperationContinuation<Int>()
        let operation = CancellationCountingOperation()
        completion.install(operation)
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
            }
        }

        completion.resume(returning: 42)
        completion.cancel()

        #expect(try await task.value == 42)
        #expect(operation.cancellationCount == 0)
    }

    @Test
    func operationCompletionReleasesInstalledAndLateOperations() {
        let completion = CloudKitOperationContinuation<Int>()
        var installedOperation: Operation? = Operation()
        let releasedInstalledOperation = WeakOperationReference(installedOperation)
        completion.install(installedOperation!)

        completion.resume(returning: 42)
        installedOperation = nil
        #expect(releasedInstalledOperation.value == nil)

        var lateOperation: Operation? = Operation()
        let releasedLateOperation = WeakOperationReference(lateOperation)
        completion.install(lateOperation!)
        lateOperation = nil
        #expect(releasedLateOperation.value == nil)
    }

    @Test
    func taskWaiterCancellationDoesNotWaitForSharedResult() async {
        let waiter = CloudKitTaskContinuation<Int>()
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
            }
        }

        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        waiter.resume(with: .success(42))
    }
}

private final class CancellationCountingOperation: Operation, @unchecked Sendable {
    private(set) var cancellationCount = 0

    override func cancel() {
        cancellationCount += 1
        super.cancel()
    }
}

private final class WeakOperationReference {
    weak var value: Operation?

    init(_ value: Operation?) {
        self.value = value
    }
}
