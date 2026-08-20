import XCTest
@testable import VVTerm

@MainActor
private final class StatsPreferencesCloudStub: StatsPreferencesCloudClient {
    var result: StatsPreferences?
    private(set) var syncCallCount = 0
    var onSync: (() -> Void)?
    var syncHandler: ((StatsPreferences) async throws -> StatsPreferences)?

    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences {
        syncCallCount += 1
        onSync?()
        if let syncHandler {
            return try await syncHandler(localPreferences)
        }
        return result ?? localPreferences
    }
}

@MainActor
private final class StatsPreferencesMutationQueueSpy: StatsPreferencesMutationQueue {
    private(set) var enqueuedPreferences: [StatsPreferences] = []
    private(set) var drainCount = 0
    var onEnqueue: (() -> Void)?
    var onDrain: (() -> Void)?
    var enqueueError: Error?

    func enqueueStatsPreferencesUpsert(_ preferences: StatsPreferences) throws {
        onEnqueue?()
        if let enqueueError { throw enqueueError }
        enqueuedPreferences.append(preferences)
    }

    func drainPendingMutations() async {
        drainCount += 1
        onDrain?()
    }
}

private enum StatsPreferencesMutationQueueTestError: Error {
    case rejected
}

@MainActor
private final class StatsPreferencesSyncLifecycleStub: StatsPreferencesSyncLifecycle {
    private var observers: [UUID: (CloudKitSyncLifecycleEvent) -> Void] = [:]
    private(set) var removedObserverIDs: [UUID] = []
    var onRemove: (() -> Void)?

    func observe(
        _ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        removedObserverIDs.append(id)
        onRemove?()
    }

    func publish(_ event: CloudKitSyncLifecycleEvent) {
        for observer in observers.values {
            observer(event)
        }
    }
}

@MainActor
private final class StatsPreferencesDebounceGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var onWait: (() -> Void)?
    var onCancel: (() -> Void)?

    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                onWait?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.onCancel?()
            }
        }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class StatsPreferencesCloudGate {
    private var continuation: CheckedContinuation<StatsPreferences, Never>?
    var onWait: (() -> Void)?
    var onCancel: (() -> Void)?

    func wait(_ localPreferences: StatsPreferences) async throws -> StatsPreferences {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                onWait?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.onCancel?()
            }
        }
    }

    func resolve(_ preferences: StatsPreferences) {
        continuation?.resume(returning: preferences)
        continuation = nil
    }
}

@MainActor
private final class StatsPreferencesResolutionSourceStub: StatsPreferencesResolutionSource {
    private var observers: [UUID: (StatsPreferences) -> Void] = [:]
    private(set) var removedObserverIDs: [UUID] = []
    var onRemove: (() -> Void)?

    func observeStatsPreferences(
        _ observer: @escaping (StatsPreferences) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeStatsPreferencesObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        removedObserverIDs.append(id)
        onRemove?()
    }

    func publish(_ preferences: StatsPreferences) {
        for observer in observers.values {
            observer(preferences)
        }
    }
}

@MainActor
private final class StatsPreferencesStoreSpy: StatsPreferencesPersisting {
    private let initialPreferences: StatsPreferences
    private(set) var savedPreferences: [StatsPreferences] = []

    init(initialPreferences: StatsPreferences) {
        self.initialPreferences = initialPreferences
    }

    func loadPreferences(defaultWriterID: String) -> StatsPreferences {
        initialPreferences
    }

    func savePreferences(_ preferences: StatsPreferences) {
        savedPreferences.append(preferences)
    }
}

@MainActor
final class PreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let persistenceKey = "test.stats-preferences"
    private let writerID = "test-writer"

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLiveDependenciesRouteInjectedOwnersAndFacts() {
        let cloud = StatsPreferencesCloudStub()
        let queue = StatsPreferencesMutationQueueSpy()
        let lifecycle = StatsPreferencesSyncLifecycleStub()
        let resolutionSource = StatsPreferencesResolutionSourceStub()
        let now = Date(timeIntervalSince1970: 123)
        var syncEnabled = true
        let dependencies = PreferencesStoreDependencies.live(
            defaults: defaults,
            cloud: cloud,
            mutationQueue: queue,
            syncLifecycle: lifecycle,
            resolutionSource: resolutionSource,
            writerID: writerID,
            isSyncEnabled: { syncEnabled },
            now: { now }
        )

        XCTAssertTrue(dependencies.cloud === cloud)
        XCTAssertTrue(dependencies.mutationQueue === queue)
        XCTAssertTrue(dependencies.syncLifecycle === lifecycle)
        XCTAssertTrue(dependencies.resolutionSource === resolutionSource)
        XCTAssertEqual(dependencies.writerID, writerID)
        XCTAssertTrue(dependencies.isSyncEnabled())
        syncEnabled = false
        XCTAssertFalse(dependencies.isSyncEnabled())
        XCTAssertEqual(dependencies.now(), now)
        XCTAssertTrue(dependencies.startsSynchronization)
        XCTAssertEqual(
            dependencies.persistence.loadPreferences(
                defaultWriterID: writerID
            ).lastWriterDeviceId,
            writerID
        )
        XCTAssertNotNil(
            defaults.data(
                forKey: UserDefaultsStatsPreferencesStore.storageKey
            )
        )
    }

    func testDefaultPreferencesReceiveApplicationWriterIdentity() {
        let store = makeStore()

        XCTAssertEqual(store.preferences.lastWriterDeviceId, writerID)
        XCTAssertNotNil(defaults.data(forKey: persistenceKey))
    }

    func testStoreLoadsAndSavesOnlyThroughInjectedPersistence() {
        let initial = StatsPreferences.defaultValue(lastWriterDeviceId: writerID)
        let persistence = StatsPreferencesStoreSpy(initialPreferences: initial)
        let store = makeStore(persistence: persistence)

        XCTAssertEqual(store.preferences, initial)

        store.setStyle(.classic)

        XCTAssertEqual(persistence.savedPreferences, [store.preferences])
    }

    func testLegacyEmptyWriterReceivesApplicationWriterIdentity() throws {
        let legacy = StatsPreferences(
            style: .cardsDetailed,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: .distantPast,
            lastWriterDeviceId: ""
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: persistenceKey
        )

        let store = makeStore()

        XCTAssertEqual(store.preferences.lastWriterDeviceId, writerID)
    }

    func testTypedCloudResolutionAppliesOnlyStatsPreferences() {
        let resolutionSource = StatsPreferencesResolutionSourceStub()
        let store = makeStore(
            resolutionSource: resolutionSource,
            startsSynchronization: true
        )
        let remote = StatsPreferences(
            style: .classic,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(),
            lastWriterDeviceId: "remote"
        )

        resolutionSource.publish(remote)

        XCTAssertEqual(store.preferences.style, .classic)
        XCTAssertEqual(store.preferences.lastWriterDeviceId, "remote")
    }

    func testInjectedClockControlsPreferenceMutation() {
        let now = Date(timeIntervalSince1970: 1234)
        let store = makeStore(now: { now })

        store.setStyle(.classic)

        XCTAssertEqual(store.preferences.updatedAt, now)
        XCTAssertEqual(store.preferences.lastWriterDeviceId, writerID)
    }

    func testForegroundAndSyncEnabledUseInjectedLifecycleAndSyncState() async {
        let cloud = StatsPreferencesCloudStub()
        let queue = StatsPreferencesMutationQueueSpy()
        let lifecycle = StatsPreferencesSyncLifecycleStub()
        var syncEnabled = false
        let store = makeStore(
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { syncEnabled },
            startsSynchronization: true
        )
        _ = store
        lifecycle.publish(.foreground)
        XCTAssertEqual(cloud.syncCallCount, 0)

        let synced = expectation(description: "enabled lifecycle sync")
        let enabledDrained = expectation(description: "enabled lifecycle drain")
        cloud.onSync = { synced.fulfill() }
        queue.onDrain = { enabledDrained.fulfill() }
        syncEnabled = true
        lifecycle.publish(.syncEnabled)
        await fulfillment(of: [synced, enabledDrained], timeout: 1)

        XCTAssertEqual(cloud.syncCallCount, 1)
        XCTAssertEqual(queue.drainCount, 1)
    }

    func testDebounceCoalescesMutationsAndSyncDisabledCancelsPendingWork() async {
        let queue = StatsPreferencesMutationQueueSpy()
        let lifecycle = StatsPreferencesSyncLifecycleStub()
        let debounce = StatsPreferencesDebounceGate()
        let firstWait = expectation(description: "first debounce wait")
        debounce.onWait = { firstWait.fulfill() }
        let startupDrained = expectation(description: "startup drain")
        queue.onDrain = { startupDrained.fulfill() }
        let store = makeStore(
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { true },
            waitForSyncDebounce: debounce.wait,
            startsSynchronization: true
        )
        await fulfillment(of: [startupDrained], timeout: 1)
        queue.onDrain = nil

        store.setStyle(.classic)
        await fulfillment(of: [firstWait], timeout: 1)
        let secondWait = expectation(description: "replacement debounce wait")
        debounce.onWait = { secondWait.fulfill() }
        store.setStyle(.cardsCompact)
        await fulfillment(of: [secondWait], timeout: 1)
        let enqueued = expectation(description: "coalesced stats enqueue")
        queue.onEnqueue = { enqueued.fulfill() }
        debounce.releaseAll()
        await fulfillment(of: [enqueued], timeout: 1)
        XCTAssertEqual(queue.enqueuedPreferences.count, 1)

        let thirdWait = expectation(description: "pending disabled debounce")
        let thirdCancelled = expectation(description: "disabled debounce cancellation observed")
        debounce.onWait = { thirdWait.fulfill() }
        debounce.onCancel = { thirdCancelled.fulfill() }
        store.setStyle(.cardsDetailed)
        await fulfillment(of: [thirdWait], timeout: 1)
        lifecycle.publish(.syncDisabled)
        await fulfillment(of: [thirdCancelled], timeout: 1)
        debounce.releaseAll()
        await Task.yield()
        XCTAssertEqual(queue.enqueuedPreferences.count, 1)
    }

    func testQueueFailureDoesNotStartDrain() async {
        let queue = StatsPreferencesMutationQueueSpy()
        queue.enqueueError = StatsPreferencesMutationQueueTestError.rejected
        let attempted = expectation(description: "stats enqueue attempted")
        queue.onEnqueue = { attempted.fulfill() }
        let store = makeStore(
            queue: queue,
            isSyncEnabled: { true },
            waitForSyncDebounce: {},
            startsSynchronization: false
        )

        store.setStyle(.classic)
        await fulfillment(of: [attempted], timeout: 1)
        await Task.yield()

        XCTAssertTrue(queue.enqueuedPreferences.isEmpty)
        XCTAssertEqual(queue.drainCount, 0)
    }

    func testBlockedStartupDoesNotRetainOwnerAndObservesCancellation() async {
        let cloud = StatsPreferencesCloudStub()
        let queue = StatsPreferencesMutationQueueSpy()
        let gate = StatsPreferencesCloudGate()
        let started = expectation(description: "blocked startup began")
        let cancelled = expectation(description: "blocked startup cancelled")
        gate.onWait = { started.fulfill() }
        gate.onCancel = { cancelled.fulfill() }
        cloud.syncHandler = gate.wait
        var store: PreferencesStore? = makeStore(
            cloud: cloud,
            queue: queue,
            isSyncEnabled: { true },
            startsSynchronization: true
        )
        weak var releasedStore: PreferencesStore?
        releasedStore = store

        await fulfillment(of: [started], timeout: 1)
        store = nil
        await fulfillment(of: [cancelled], timeout: 1)

        XCTAssertNil(releasedStore)
        XCTAssertEqual(queue.drainCount, 0)
        gate.resolve(.defaultValue(lastWriterDeviceId: "remote"))
    }

    func testBlockedDebounceDoesNotRetainOwnerAndObservesCancellation() async {
        let queue = StatsPreferencesMutationQueueSpy()
        let debounce = StatsPreferencesDebounceGate()
        let started = expectation(description: "blocked debounce began")
        let cancelled = expectation(description: "blocked debounce cancelled")
        debounce.onWait = { started.fulfill() }
        debounce.onCancel = { cancelled.fulfill() }
        var store: PreferencesStore? = makeStore(
            queue: queue,
            isSyncEnabled: { true },
            waitForSyncDebounce: debounce.wait
        )
        weak var releasedStore: PreferencesStore?
        releasedStore = store

        store?.setStyle(.classic)
        await fulfillment(of: [started], timeout: 1)
        store = nil
        await fulfillment(of: [cancelled], timeout: 1)

        XCTAssertNil(releasedStore)
        debounce.releaseAll()
        await Task.yield()
        XCTAssertTrue(queue.enqueuedPreferences.isEmpty)
    }

    func testSyncDisabledRejectsBlockedStartupCompletionAndSkipsDrain() async {
        let cloud = StatsPreferencesCloudStub()
        let queue = StatsPreferencesMutationQueueSpy()
        let lifecycle = StatsPreferencesSyncLifecycleStub()
        let gate = StatsPreferencesCloudGate()
        let started = expectation(description: "blocked startup began")
        let cancelled = expectation(description: "blocked startup cancelled")
        gate.onWait = { started.fulfill() }
        gate.onCancel = { cancelled.fulfill() }
        cloud.syncHandler = gate.wait
        var syncEnabled = true
        let store = makeStore(
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { syncEnabled },
            startsSynchronization: true
        )
        let remote = StatsPreferences(
            style: .classic,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSince1970: 2),
            lastWriterDeviceId: "remote"
        )

        await fulfillment(of: [started], timeout: 1)
        syncEnabled = false
        lifecycle.publish(.syncDisabled)
        await fulfillment(of: [cancelled], timeout: 1)
        gate.resolve(remote)
        await Task.yield()

        XCTAssertNotEqual(store.preferences.style, .classic)
        XCTAssertEqual(store.preferences.lastWriterDeviceId, writerID)
        XCTAssertEqual(queue.drainCount, 0)
    }

    func testDeinitRemovesInjectedLifecycleAndResolutionObservers() async {
        let lifecycle = StatsPreferencesSyncLifecycleStub()
        let resolutionSource = StatsPreferencesResolutionSourceStub()
        let lifecycleRemoved = expectation(description: "lifecycle observer removed")
        let resolutionRemoved = expectation(description: "resolution observer removed")
        lifecycle.onRemove = { lifecycleRemoved.fulfill() }
        resolutionSource.onRemove = { resolutionRemoved.fulfill() }
        var store: PreferencesStore? = makeStore(
            lifecycle: lifecycle,
            resolutionSource: resolutionSource,
            startsSynchronization: true
        )
        weak var releasedStore: PreferencesStore?
        releasedStore = store

        store = nil
        await fulfillment(of: [lifecycleRemoved, resolutionRemoved], timeout: 1)

        XCTAssertNil(releasedStore)
        XCTAssertEqual(lifecycle.removedObserverIDs.count, 1)
        XCTAssertEqual(resolutionSource.removedObserverIDs.count, 1)
    }

    private func makeStore(
        persistence: (any StatsPreferencesPersisting)? = nil,
        cloud: StatsPreferencesCloudStub? = nil,
        queue: StatsPreferencesMutationQueueSpy? = nil,
        lifecycle: StatsPreferencesSyncLifecycleStub? = nil,
        resolutionSource: StatsPreferencesResolutionSourceStub? = nil,
        isSyncEnabled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init,
        waitForSyncDebounce: @escaping () async throws -> Void = {},
        startsSynchronization: Bool = false
    ) -> PreferencesStore {
        let cloud = cloud ?? StatsPreferencesCloudStub()
        let queue = queue ?? StatsPreferencesMutationQueueSpy()
        let lifecycle = lifecycle ?? StatsPreferencesSyncLifecycleStub()
        let resolutionSource = resolutionSource ?? StatsPreferencesResolutionSourceStub()
        return PreferencesStore(
            dependencies: PreferencesStoreDependencies(
                persistence: persistence ?? UserDefaultsStatsPreferencesStore(
                    defaults: defaults,
                    key: persistenceKey
                ),
                cloud: cloud,
                mutationQueue: queue,
                syncLifecycle: lifecycle,
                resolutionSource: resolutionSource,
                writerID: writerID,
                isSyncEnabled: isSyncEnabled,
                now: now,
                waitForSyncDebounce: waitForSyncDebounce,
                startsSynchronization: startsSynchronization
            )
        )
    }
}
