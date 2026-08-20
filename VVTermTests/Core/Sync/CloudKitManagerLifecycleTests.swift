import CloudKit
import Foundation
import Testing
@testable import VVTerm

private actor CloudKitAccountStatusGate {
    private var continuations: [CheckedContinuation<CKAccountStatus, Never>] = []

    func next() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForPendingRequest() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if !continuations.isEmpty { return true }
            await Task.yield()
        }
        return !continuations.isEmpty
    }

    func resumeNext(with status: CKAccountStatus) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: status)
    }
}

private actor CloudKitOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CloudKitSyncEnabledState {
    var value = true
}

@Suite(.serialized)
@MainActor
struct CloudKitManagerLifecycleTests {
    @Test
    func disabledInitializationPublishesDisabledState() {
        let syncEnabled = CloudKitSyncEnabledState()
        syncEnabled.value = false
        let manager = CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { syncEnabled.value },
            accountStatus: { .available }
        )

        #expect(manager.accountState == .disabled)
        #expect(manager.syncStatus == .disabled)
    }

    @Test
    func disableAndReenableRejectsStaleAccountStatus() async {
        let gate = CloudKitAccountStatusGate()
        let syncEnabled = CloudKitSyncEnabledState()
        let manager = CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { syncEnabled.value },
            accountStatus: { await gate.next() }
        )
        #expect(await gate.waitForPendingRequest())

        syncEnabled.value = false
        manager.handleSyncToggle(false)
        #expect(manager.accountState == .disabled)
        #expect(manager.syncStatus == .disabled)

        await gate.resumeNext(with: .available)
        await settleMainActor()
        #expect(manager.accountState == .disabled)
        #expect(manager.syncStatus == .disabled)

        syncEnabled.value = true
        manager.handleSyncToggle(true)
        #expect(manager.accountState == .checking)
        #expect(await gate.waitForPendingRequest())
        await gate.resumeNext(with: .noAccount)

        #expect(await waitUntil { manager.accountState == .noAccount })
        #expect(manager.syncStatus == .offline)
    }

    @Test
    func disableAndReenableRejectsStaleMutationSuccess() async {
        let syncEnabled = CloudKitSyncEnabledState()
        let manager = CloudKitManager(
            container: CKContainer(
                identifier: CloudKitSyncConstants.cloudKitContainerIdentifier
            ),
            syncEnabled: { syncEnabled.value },
            accountStatus: { .available },
            initialZoneReady: true
        )
        #expect(await waitUntil { manager.isAvailable })
        let gate = CloudKitOperationGate()
        let staleMutation = Task {
            try await manager.performCloudKitRecordMutation {
                await gate.wait()
            }
        }
        #expect(await gate.waitUntilBlocked())

        syncEnabled.value = false
        manager.handleSyncToggle(false)
        syncEnabled.value = true
        manager.handleSyncToggle(true)
        await gate.resume()

        do {
            try await staleMutation.value
            Issue.record("Expected stale CloudKit mutation cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(manager.lastSyncDate == nil)
    }

    private func settleMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
