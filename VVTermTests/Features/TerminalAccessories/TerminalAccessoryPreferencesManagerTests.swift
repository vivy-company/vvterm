import XCTest
@testable import VVTerm

@MainActor
private final class TerminalAccessoryCloudStub: TerminalAccessoryCloudClient {
    var result: TerminalAccessoryProfile?
    private(set) var syncCallCount = 0
    var onSync: (() -> Void)?
    var syncHandler: ((TerminalAccessoryProfile) async throws -> TerminalAccessoryProfile)?

    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        syncCallCount += 1
        onSync?()
        if let syncHandler {
            return try await syncHandler(localProfile)
        }
        return result ?? localProfile
    }
}

@MainActor
private final class TerminalAccessoryMutationQueueSpy: TerminalAccessoryMutationQueue {
    private(set) var enqueuedProfiles: [TerminalAccessoryProfile] = []
    private(set) var drainCount = 0
    var onEnqueue: (() -> Void)?
    var onDrain: (() -> Void)?
    var enqueueError: Error?

    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) throws {
        onEnqueue?()
        if let enqueueError { throw enqueueError }
        enqueuedProfiles.append(profile)
    }

    func drainPendingMutations() async {
        drainCount += 1
        onDrain?()
    }
}

private enum TerminalAccessoryMutationQueueTestError: Error {
    case rejected
}

@MainActor
private final class TerminalAccessorySyncLifecycleStub: TerminalAccessorySyncLifecycle {
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
private final class TerminalAccessoryDebounceGate {
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
private final class TerminalAccessoryCloudGate {
    private var continuation: CheckedContinuation<TerminalAccessoryProfile, Never>?
    var onWait: (() -> Void)?
    var onCancel: (() -> Void)?

    func wait(
        localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
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

    func resolve(_ profile: TerminalAccessoryProfile) {
        continuation?.resume(returning: profile)
        continuation = nil
    }
}

@MainActor
private final class TerminalAccessoryResolutionSourceStub: TerminalAccessoryResolutionSource {
    private var observers: [UUID: (TerminalAccessoryProfile) -> Void] = [:]
    private(set) var removedObserverIDs: [UUID] = []
    var onRemove: (() -> Void)?

    func observeTerminalAccessoryProfile(
        _ observer: @escaping (TerminalAccessoryProfile) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeTerminalAccessoryProfileObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        removedObserverIDs.append(id)
        onRemove?()
    }

    func publish(_ profile: TerminalAccessoryProfile) {
        for observer in observers.values {
            observer(profile)
        }
    }
}

@MainActor
private final class TerminalAccessoryAnalyticsSpy {
    private(set) var createdKinds: [TerminalAccessoryCustomActionKind] = []

    func record(_ kind: TerminalAccessoryCustomActionKind) {
        createdKinds.append(kind)
    }
}

@MainActor
private final class TerminalAccessoryProfileStoreSpy: TerminalAccessoryProfilePersisting {
    private let initialProfile: TerminalAccessoryProfile
    private(set) var savedProfiles: [TerminalAccessoryProfile] = []

    init(initialProfile: TerminalAccessoryProfile) {
        self.initialProfile = initialProfile
    }

    func loadProfile(defaultWriterID: String) -> TerminalAccessoryProfile {
        initialProfile
    }

    func saveProfile(_ profile: TerminalAccessoryProfile) {
        savedProfiles.append(profile)
    }
}

@MainActor
final class TerminalAccessoryPreferencesManagerTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private let persistenceKey = "test.terminal-accessory-profile"
    private let writerID = "test-writer"

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "TerminalAccessoryPreferencesManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testLiveDependenciesRouteInjectedOwnersAndFacts() {
        let cloud = TerminalAccessoryCloudStub()
        let queue = TerminalAccessoryMutationQueueSpy()
        let lifecycle = TerminalAccessorySyncLifecycleStub()
        let resolutionSource = TerminalAccessoryResolutionSourceStub()
        let analytics = TerminalAccessoryAnalyticsSpy()
        let now = Date(timeIntervalSince1970: 123)
        let actionID = UUID()
        var syncEnabled = true
        let dependencies = TerminalAccessoryPreferencesDependencies.live(
            defaults: defaults,
            cloud: cloud,
            mutationQueue: queue,
            syncLifecycle: lifecycle,
            resolutionSource: resolutionSource,
            writerID: writerID,
            isSyncEnabled: { syncEnabled },
            now: { now },
            makeID: { actionID },
            trackCustomActionCreated: analytics.record
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
        XCTAssertEqual(dependencies.makeID(), actionID)
        XCTAssertTrue(dependencies.startsSynchronization)

        dependencies.trackCustomActionCreated(.command)
        XCTAssertEqual(analytics.createdKinds, [.command])
        XCTAssertEqual(
            dependencies.profileStore.loadProfile(
                defaultWriterID: writerID
            ).lastWriterDeviceId,
            writerID
        )
        XCTAssertNotNil(
            defaults.data(
                forKey: UserDefaultsTerminalAccessoryProfileStore.storageKey
            )
        )
    }

    func testCreateCustomActionPersistsAndUpdatesProfileMetadata() throws {
        let now = Date(timeIntervalSince1970: 1234)
        let actionID = UUID()
        let analytics = TerminalAccessoryAnalyticsSpy()
        let manager = makeManager(
            now: { now },
            makeID: { actionID },
            analytics: analytics
        )

        let action = try manager.createCustomAction(
            title: "List Files",
            kind: .command,
            commandContent: "ls -la",
            commandSendMode: .insertAndEnter,
            shortcutKey: .l,
            shortcutModifiers: .init(control: true),
            hasProAccess: false
        )

        XCTAssertEqual(manager.customActions.map(\.id), [action.id])
        XCTAssertEqual(action.id, actionID)
        XCTAssertEqual(action.updatedAt, now)
        XCTAssertEqual(manager.profile.lastWriterDeviceId, writerID)
        XCTAssertEqual(manager.profile.customActions.first?.commandContent, "ls -la")
        XCTAssertNotNil(defaults.data(forKey: persistenceKey))
        XCTAssertEqual(analytics.createdKinds, [.command])
    }

    func testManagerLoadsAndSavesOnlyThroughInjectedProfileStore() {
        let initialProfile = TerminalAccessoryProfile.defaultValue(
            lastWriterDeviceId: writerID
        )
        let profileStore = TerminalAccessoryProfileStoreSpy(
            initialProfile: initialProfile
        )
        let manager = makeManager(profileStore: profileStore)

        XCTAssertEqual(manager.profile, initialProfile)

        manager.removeActiveItem(.system(.escape))

        XCTAssertEqual(profileStore.savedProfiles, [manager.profile])
    }

    func testResetToDefaultLayoutRestoresActiveItems() {
        let manager = makeManager()
        manager.removeActiveItem(.system(.escape))

        XCTAssertNotEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)

        manager.resetToDefaultLayout()

        XCTAssertEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)
        XCTAssertEqual(manager.profile.lastWriterDeviceId, writerID)
    }

    func testExplicitProAccessFactControlsCustomActionGate() throws {
        let manager = makeManager()

        for index in 0..<FreeTierLimits.maxCustomActions {
            _ = try manager.createCustomAction(
                title: "Action \(index)",
                kind: .command,
                commandContent: "echo \(index)",
                commandSendMode: .insertAndEnter,
                shortcutKey: .a,
                shortcutModifiers: .init(),
                hasProAccess: true
            )
        }

        XCTAssertTrue(manager.isCustomActionCreationProGated(hasProAccess: false))
        XCTAssertFalse(manager.isCustomActionCreationProGated(hasProAccess: true))
        XCTAssertEqual(
            manager.customActionLimit(hasProAccess: false),
            FreeTierLimits.maxCustomActions
        )
        XCTAssertEqual(
            manager.customActionLimit(hasProAccess: true),
            TerminalAccessoryProfile.maxCustomActions
        )
    }

    func testLegacyProfileWithoutWriterReceivesApplicationWriterIdentity() throws {
        let profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "legacy")
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "lastWriterDeviceId")
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: persistenceKey
        )

        let manager = makeManager()

        XCTAssertEqual(manager.profile.lastWriterDeviceId, writerID)
    }

    func testTypedCloudResolutionAppliesOnlyAccessoryProfile() {
        let resolutionSource = TerminalAccessoryResolutionSourceStub()
        let manager = makeManager(
            resolutionSource: resolutionSource,
            startsSynchronization: true
        )
        let updatedAt = Date()
        let remote = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: Array(TerminalAccessoryProfile.defaultActiveItems.reversed()),
                updatedAt: updatedAt
            ),
            customActions: [],
            updatedAt: updatedAt,
            lastWriterDeviceId: "remote"
        )

        resolutionSource.publish(remote)

        XCTAssertEqual(manager.activeItems, Array(TerminalAccessoryProfile.defaultActiveItems.reversed()))
        XCTAssertEqual(manager.profile.lastWriterDeviceId, "remote")
    }

    func testForegroundAndSyncEnabledUseInjectedLifecycleAndSyncState() async {
        let cloud = TerminalAccessoryCloudStub()
        let queue = TerminalAccessoryMutationQueueSpy()
        let lifecycle = TerminalAccessorySyncLifecycleStub()
        var syncEnabled = false
        let manager = makeManager(
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { syncEnabled },
            startsSynchronization: true
        )
        _ = manager
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
        let queue = TerminalAccessoryMutationQueueSpy()
        let lifecycle = TerminalAccessorySyncLifecycleStub()
        let debounce = TerminalAccessoryDebounceGate()
        let firstWait = expectation(description: "first debounce wait")
        debounce.onWait = { firstWait.fulfill() }
        let startupDrained = expectation(description: "startup drain")
        queue.onDrain = { startupDrained.fulfill() }
        let manager = makeManager(
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { true },
            waitForSyncDebounce: debounce.wait,
            startsSynchronization: true
        )
        await fulfillment(of: [startupDrained], timeout: 1)
        queue.onDrain = nil

        manager.removeActiveItem(.system(.escape))
        await fulfillment(of: [firstWait], timeout: 1)
        let secondWait = expectation(description: "replacement debounce wait")
        debounce.onWait = { secondWait.fulfill() }
        manager.resetToDefaultLayout()
        await fulfillment(of: [secondWait], timeout: 1)
        let enqueued = expectation(description: "coalesced profile enqueue")
        queue.onEnqueue = { enqueued.fulfill() }
        debounce.releaseAll()
        await fulfillment(of: [enqueued], timeout: 1)
        XCTAssertEqual(queue.enqueuedProfiles.count, 1)

        let thirdWait = expectation(description: "pending disabled debounce")
        let thirdCancelled = expectation(description: "disabled debounce cancellation observed")
        debounce.onWait = { thirdWait.fulfill() }
        debounce.onCancel = { thirdCancelled.fulfill() }
        manager.removeActiveItem(.system(.tab))
        await fulfillment(of: [thirdWait], timeout: 1)
        lifecycle.publish(.syncDisabled)
        await fulfillment(of: [thirdCancelled], timeout: 1)
        debounce.releaseAll()
        await Task.yield()
        XCTAssertEqual(queue.enqueuedProfiles.count, 1)
    }

    func testQueueFailureDoesNotStartDrain() async {
        let queue = TerminalAccessoryMutationQueueSpy()
        queue.enqueueError = TerminalAccessoryMutationQueueTestError.rejected
        let attempted = expectation(description: "accessory enqueue attempted")
        queue.onEnqueue = { attempted.fulfill() }
        let manager = makeManager(
            queue: queue,
            isSyncEnabled: { true },
            waitForSyncDebounce: {},
            startsSynchronization: false
        )

        manager.removeActiveItem(.system(.escape))
        await fulfillment(of: [attempted], timeout: 1)
        await Task.yield()

        XCTAssertTrue(queue.enqueuedProfiles.isEmpty)
        XCTAssertEqual(queue.drainCount, 0)
    }

    func testBlockedStartupDoesNotRetainOwnerAndObservesCancellation() async {
        let cloud = TerminalAccessoryCloudStub()
        let queue = TerminalAccessoryMutationQueueSpy()
        let gate = TerminalAccessoryCloudGate()
        let started = expectation(description: "blocked startup began")
        let cancelled = expectation(description: "blocked startup cancelled")
        gate.onWait = { started.fulfill() }
        gate.onCancel = { cancelled.fulfill() }
        cloud.syncHandler = gate.wait
        var manager: TerminalAccessoryPreferencesManager? = makeManager(
            cloud: cloud,
            queue: queue,
            isSyncEnabled: { true },
            startsSynchronization: true
        )
        weak var releasedManager: TerminalAccessoryPreferencesManager?
        releasedManager = manager

        await fulfillment(of: [started], timeout: 1)
        manager = nil
        await fulfillment(of: [cancelled], timeout: 1)

        XCTAssertNil(releasedManager)
        XCTAssertEqual(queue.drainCount, 0)
        gate.resolve(TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "remote"))
    }

    func testBlockedDebounceDoesNotRetainOwnerAndObservesCancellation() async {
        let queue = TerminalAccessoryMutationQueueSpy()
        let debounce = TerminalAccessoryDebounceGate()
        let started = expectation(description: "blocked debounce began")
        let cancelled = expectation(description: "blocked debounce cancelled")
        debounce.onWait = { started.fulfill() }
        debounce.onCancel = { cancelled.fulfill() }
        var manager: TerminalAccessoryPreferencesManager? = makeManager(
            queue: queue,
            isSyncEnabled: { true },
            waitForSyncDebounce: debounce.wait
        )
        weak var releasedManager: TerminalAccessoryPreferencesManager?
        releasedManager = manager

        manager?.removeActiveItem(.system(.escape))
        await fulfillment(of: [started], timeout: 1)
        manager = nil
        await fulfillment(of: [cancelled], timeout: 1)

        XCTAssertNil(releasedManager)
        debounce.releaseAll()
        await Task.yield()
        XCTAssertTrue(queue.enqueuedProfiles.isEmpty)
    }

    func testSyncDisabledRejectsBlockedStartupCompletionAndSkipsDrain() async {
        let cloud = TerminalAccessoryCloudStub()
        let queue = TerminalAccessoryMutationQueueSpy()
        let lifecycle = TerminalAccessorySyncLifecycleStub()
        let gate = TerminalAccessoryCloudGate()
        let started = expectation(description: "blocked startup began")
        let cancelled = expectation(description: "blocked startup cancelled")
        gate.onWait = { started.fulfill() }
        gate.onCancel = { cancelled.fulfill() }
        cloud.syncHandler = gate.wait
        var syncEnabled = true
        let manager = makeManager(
            cloud: cloud,
            queue: queue,
            lifecycle: lifecycle,
            isSyncEnabled: { syncEnabled },
            startsSynchronization: true
        )
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2)
        let remote = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: Array(TerminalAccessoryProfile.defaultActiveItems.reversed()),
                updatedAt: remoteUpdatedAt
            ),
            customActions: [],
            updatedAt: remoteUpdatedAt,
            lastWriterDeviceId: "remote"
        )

        await fulfillment(of: [started], timeout: 1)
        syncEnabled = false
        lifecycle.publish(.syncDisabled)
        await fulfillment(of: [cancelled], timeout: 1)
        gate.resolve(remote)
        await Task.yield()

        XCTAssertEqual(manager.profile.lastWriterDeviceId, writerID)
        XCTAssertNotEqual(
            manager.activeItems,
            Array(TerminalAccessoryProfile.defaultActiveItems.reversed())
        )
        XCTAssertEqual(queue.drainCount, 0)
    }

    func testDeinitRemovesInjectedLifecycleAndResolutionObservers() async {
        let lifecycle = TerminalAccessorySyncLifecycleStub()
        let resolutionSource = TerminalAccessoryResolutionSourceStub()
        let lifecycleRemoved = expectation(description: "lifecycle observer removed")
        let resolutionRemoved = expectation(description: "resolution observer removed")
        lifecycle.onRemove = { lifecycleRemoved.fulfill() }
        resolutionSource.onRemove = { resolutionRemoved.fulfill() }
        var manager: TerminalAccessoryPreferencesManager? = makeManager(
            lifecycle: lifecycle,
            resolutionSource: resolutionSource,
            startsSynchronization: true
        )
        weak var releasedManager: TerminalAccessoryPreferencesManager?
        releasedManager = manager

        manager = nil
        await fulfillment(of: [lifecycleRemoved, resolutionRemoved], timeout: 1)

        XCTAssertNil(releasedManager)
        XCTAssertEqual(lifecycle.removedObserverIDs.count, 1)
        XCTAssertEqual(resolutionSource.removedObserverIDs.count, 1)
    }

    private func makeManager(
        profileStore: (any TerminalAccessoryProfilePersisting)? = nil,
        cloud: TerminalAccessoryCloudStub? = nil,
        queue: TerminalAccessoryMutationQueueSpy? = nil,
        lifecycle: TerminalAccessorySyncLifecycleStub? = nil,
        resolutionSource: TerminalAccessoryResolutionSourceStub? = nil,
        isSyncEnabled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init,
        analytics: TerminalAccessoryAnalyticsSpy? = nil,
        waitForSyncDebounce: @escaping () async throws -> Void = {},
        startsSynchronization: Bool = false
    ) -> TerminalAccessoryPreferencesManager {
        let cloud = cloud ?? TerminalAccessoryCloudStub()
        let queue = queue ?? TerminalAccessoryMutationQueueSpy()
        let lifecycle = lifecycle ?? TerminalAccessorySyncLifecycleStub()
        let resolutionSource = resolutionSource ?? TerminalAccessoryResolutionSourceStub()
        let analytics = analytics ?? TerminalAccessoryAnalyticsSpy()
        return TerminalAccessoryPreferencesManager(
            dependencies: TerminalAccessoryPreferencesDependencies(
                profileStore: profileStore ?? UserDefaultsTerminalAccessoryProfileStore(
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
                makeID: makeID,
                trackCustomActionCreated: analytics.record,
                waitForSyncDebounce: waitForSyncDebounce,
                startsSynchronization: startsSynchronization
            )
        )
    }
}
