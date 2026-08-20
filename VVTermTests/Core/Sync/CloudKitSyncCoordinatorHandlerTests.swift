import Foundation
import Testing
@testable import VVTerm

private enum PendingMutationHandlerTestError: Error {
    case failed
}

private actor PendingMutationHandlerGate {
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

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PendingMutationHandlerStub: PendingCloudKitMutationHandling {
    enum Behavior {
        case succeed
        case fail
        case cancel
        case wait(PendingMutationHandlerGate)
    }

    var behaviors: [Behavior]
    private(set) var received: [PendingCloudKitMutation] = []

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func handle(_ mutation: PendingCloudKitMutation) async throws {
        received.append(mutation)
        guard !behaviors.isEmpty else { return }
        switch behaviors.removeFirst() {
        case .succeed:
            return
        case .fail:
            throw PendingMutationHandlerTestError.failed
        case .cancel:
            throw CancellationError()
        case .wait(let gate):
            await gate.wait()
        }
    }
}

@MainActor
struct CloudKitSyncCoordinatorHandlerTests {
    @Test
    func handlerFailurePersistsRetryAndLaterSuccessRemovesMutation() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var currentDate = Date(timeIntervalSinceReferenceDate: 20_000)
        let handler = PendingMutationHandlerStub(behaviors: [.fail, .succeed])
        let generation = UUID()
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: "handlerRetryQueue",
                defaults: defaults
            ),
            isSyncEnabled: { true },
            currentGeneration: { generation },
            now: { currentDate },
            makeID: UUID.init
        )
        let theme = TerminalTheme(
            name: "Retry Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let payload = try PendingCloudKitMutationPayload.terminalThemeUpsert(theme)

        try coordinator.enqueue(
            PendingCloudKitMutation(payload: payload)
        )
        await coordinator.drainPendingMutations()

        let failedMutation = try #require(coordinator.snapshot().first)
        let firstReceivedPayload = try #require(handler.received.first?.payload)
        let decodedTheme = try firstReceivedPayload.decode(
            TerminalTheme.self,
            entityType: TerminalThemePendingCloudKitPayloadCodec.themeEntityType,
            operation: .upsert
        )
        let receivedTheme = try #require(decodedTheme)
        #expect(handler.received.map(\.payload) == [payload])
        #expect(receivedTheme == theme)
        #expect(failedMutation.retryCount == 1)
        #expect(failedMutation.nextRetryAt == currentDate.addingTimeInterval(30))

        currentDate = try #require(failedMutation.nextRetryAt)
        await coordinator.drainPendingMutations()

        let expectedReceivedPayloads = [payload, payload]
        #expect(handler.received.map(\.payload) == expectedReceivedPayloads)
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func cancellationLeavesMutationUnchangedAndImmediatelyRetryable() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let handler = PendingMutationHandlerStub(behaviors: [.cancel, .succeed])
        let generation = UUID()
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: "handlerCancellationQueue",
                defaults: defaults
            ),
            isSyncEnabled: { true },
            currentGeneration: { generation },
            now: { Date(timeIntervalSinceReferenceDate: 30_000) },
            makeID: UUID.init
        )
        let theme = TerminalTheme(
            name: "Cancelled Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let payload = try PendingCloudKitMutationPayload.terminalThemeUpsert(theme)
        let mutation = PendingCloudKitMutation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            payload: payload,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        try coordinator.enqueue(mutation)
        await coordinator.drainPendingMutations()

        #expect(coordinator.snapshot() == [mutation])
        #expect(handler.received == [mutation])

        await coordinator.drainPendingMutations()

        #expect(handler.received == [mutation, mutation])
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func removalPersistenceFailureKeepsSuccessfulMutationDurable() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.remove.\(UUID().uuidString)"
        let defaults = WriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "handlerRemovalFailureQueue"
        let handler = PendingMutationHandlerStub(behaviors: [.succeed])
        let generation = UUID()
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: storageKey,
                defaults: defaults
            ),
            isSyncEnabled: { true },
            currentGeneration: { generation },
            now: { Date(timeIntervalSinceReferenceDate: 40_000) },
            makeID: UUID.init
        )
        let mutation = try makeMutation(idSuffix: 2)
        try coordinator.enqueue(mutation)

        defaults.rejectWrites = true
        await coordinator.drainPendingMutations()

        #expect(handler.received == [mutation])
        #expect(coordinator.snapshot() == [mutation])
        defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storageKey,
            defaults: defaults
        )
        #expect(reloadedQueue.snapshot() == [mutation])
    }

    @Test
    func retryPersistenceFailureKeepsOriginalMutationDurable() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.retry.\(UUID().uuidString)"
        let defaults = WriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "handlerRetryPersistenceFailureQueue"
        let handler = PendingMutationHandlerStub(behaviors: [.fail])
        let generation = UUID()
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: storageKey,
                defaults: defaults
            ),
            isSyncEnabled: { true },
            currentGeneration: { generation },
            now: { Date(timeIntervalSinceReferenceDate: 50_000) },
            makeID: UUID.init
        )
        let mutation = try makeMutation(idSuffix: 3)
        try coordinator.enqueue(mutation)

        defaults.rejectWrites = true
        await coordinator.drainPendingMutations()

        #expect(handler.received == [mutation])
        #expect(coordinator.snapshot() == [mutation])
        defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storageKey,
            defaults: defaults
        )
        #expect(reloadedQueue.snapshot() == [mutation])
    }

    @Test
    func disableAndReenableRejectsStaleSuccessfulDrainCompletion() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.generation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gate = PendingMutationHandlerGate()
        let handler = PendingMutationHandlerStub(behaviors: [.wait(gate), .succeed])
        var isSyncEnabled = true
        var generation = UUID()
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: "handlerGenerationQueue",
                defaults: defaults
            ),
            isSyncEnabled: { isSyncEnabled },
            currentGeneration: { generation },
            now: { Date(timeIntervalSinceReferenceDate: 60_000) },
            makeID: UUID.init
        )
        let mutation = try makeMutation(idSuffix: 4)
        try coordinator.enqueue(mutation)
        let staleDrain = Task { await coordinator.drainPendingMutations() }
        #expect(await gate.waitUntilBlocked())

        isSyncEnabled = false
        generation = UUID()
        isSyncEnabled = true
        await gate.release()
        await staleDrain.value

        #expect(coordinator.snapshot() == [mutation])
        await coordinator.drainPendingMutations()
        #expect(coordinator.snapshot().isEmpty)
    }

    private func makeMutation(idSuffix: Int) throws -> PendingCloudKitMutation {
        let theme = TerminalTheme(
            name: "Durable Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        return PendingCloudKitMutation(
            id: UUID(
                uuidString: String(
                    format: "10000000-0000-0000-0000-%012d",
                    idSuffix
                )
            )!,
            payload: try PendingCloudKitMutationPayload.terminalThemeUpsert(theme),
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }
}
