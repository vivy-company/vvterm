import Foundation
import XCTest
@testable import VVTerm

@MainActor
private final class StatsTestGate<Value: Sendable> {
    private let ignoresCancellation: Bool
    private var continuation: CheckedContinuation<Value, Error>?
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started = true
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
                if cancelled, !ignoresCancellation {
                    self.continuation = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.recordCancellation()
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func succeed(with value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func recordCancellation() {
        guard !cancelled else { return }
        cancelled = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
        if !ignoresCancellation {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }
}

@MainActor
private final class StatsTestEvent {
    private var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for expectedCount: Int = 1) async {
        guard count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
    }

    var recordedCount: Int { count }
}

@MainActor
private final class StatsTestTarget: ServerStatsCollectionTarget {
    let serverID: UUID

    init(serverID: UUID = UUID()) {
        self.serverID = serverID
    }
}

@MainActor
private final class StatsTestConnection: ServerStatsConnectionReference {
    var identity: ServerStatsConnectionIdentity {
        ServerStatsConnectionIdentity(self)
    }
}

@MainActor
private final class StatsTestApprovalReference: ServerStatsApprovalReference {
    let request: ServerStatsApprovalRequest

    init(request: ServerStatsApprovalRequest) {
        self.request = request
    }
}

@MainActor
private final class StatsTestSession: ServerStatsCollectionSession {
    enum CollectionBehavior {
        case suspended(StatsTestGate<Void>)
        case collect(StatsTestGate<ServerStats>?)
    }

    let connectionIdentity: ServerStatsConnectionIdentity
    let ownership: ServerStatsClientOwnership
    let runStarted = StatsTestEvent()
    let runFinished = StatsTestEvent()
    let collectionStarted = StatsTestEvent()
    let disconnected = StatsTestEvent()
    var collectionBehavior: CollectionBehavior
    var collectionGate: StatsTestGate<ServerStats>?
    var dockerGate: StatsTestGate<DockerStats>?
    private(set) var disconnectCount = 0

    init(
        connection: StatsTestConnection,
        ownership: ServerStatsClientOwnership,
        collectionBehavior: CollectionBehavior
    ) {
        connectionIdentity = connection.identity
        self.ownership = ownership
        self.collectionBehavior = collectionBehavior
        if case .collect(let collectionGate) = collectionBehavior {
            self.collectionGate = collectionGate
        }
    }

    func runCollection(
        _ operation: @MainActor @Sendable @escaping () async throws -> Void
    ) async throws {
        runStarted.record()
        defer { runFinished.record() }
        switch collectionBehavior {
        case .suspended(let gate):
            _ = try await gate.wait()
        case .collect:
            try await operation()
        }
    }

    func disconnect() async {
        disconnectCount += 1
        disconnected.record()
    }

    func prepareIfNeeded() async -> ServerStatsCollectionPreparation? {
        nil
    }

    func collectStats(collectDocker: Bool) async throws -> ServerStats {
        collectionStarted.record()
        if let collectionGate {
            return try await collectionGate.wait()
        }
        return ServerStats()
    }

    func terminateProcess(_ process: VVTerm.ProcessInfo) async throws {}

    func loadProcesses(
        fallback: [VVTerm.ProcessInfo]
    ) async throws -> [VVTerm.ProcessInfo] {
        fallback
    }

    func loadDockerStats(fallback: DockerStats) async -> DockerStats {
        guard let dockerGate else { return fallback }
        return (try? await dockerGate.wait()) ?? fallback
    }

    func loadStorageHealth(for volume: VolumeInfo) async throws -> StorageHealthResult {
        .unavailable(.unsupported)
    }

    func performDockerAction(
        _ action: DockerContainerAction,
        on container: DockerContainer,
        fallback: DockerStats
    ) async throws -> DockerStats {
        fallback
    }
}

@MainActor
private final class StatsTestSessionFactory {
    typealias Behavior = StatsTestSession.CollectionBehavior

    var behaviors: [Behavior]
    private(set) var ownedConnections: [StatsTestConnection] = []
    private(set) var sessions: [StatsTestSession] = []

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func makeOwnedConnection() -> any ServerStatsConnectionReference {
        let connection = StatsTestConnection()
        ownedConnections.append(connection)
        return connection
    }

    func makeSession(
        target: any ServerStatsCollectionTarget,
        connection: any ServerStatsConnectionReference,
        ownership: ServerStatsClientOwnership
    ) throws -> any ServerStatsCollectionSession {
        guard let connection = connection as? StatsTestConnection else {
            throw StatsTestError.incompatibleConnection
        }
        let behavior = behaviors.isEmpty
            ? .suspended(StatsTestGate<Void>())
            : behaviors.removeFirst()
        let session = StatsTestSession(
            connection: connection,
            ownership: ownership,
            collectionBehavior: behavior
        )
        sessions.append(session)
        return session
    }
}

private enum StatsTestError: Error {
    case incompatibleConnection
}

private struct StatsExternalTestError: LocalizedError {
    var errorDescription: String? { "External stats failure." }
}

final class ServerStatsCollectorLifecycleTests: XCTestCase {
    @MainActor
    func testPresentationSnapshotUsesCurrentCollectorValues() {
        let collector = makeCollector(factory: StatsTestSessionFactory(behaviors: []))
        let timestamp = Date(timeIntervalSince1970: 42)
        let cpuPoint = StatsPoint(timestamp: timestamp, value: 55)
        let gpuPoint = StatsPoint(timestamp: timestamp, value: 34)

        collector.stats.cpuUsage = 55
        collector.cpuHistory = [cpuPoint]
        collector.gpuUtilizationHistoryByDeviceID = ["gpu-0": [gpuPoint]]

        let snapshot = collector.presentationSnapshot

        XCTAssertEqual(snapshot.stats.cpuUsage, 55)
        XCTAssertEqual(snapshot.cpuHistory.map(\.value), [55])
        XCTAssertEqual(snapshot.gpuHistories["gpu-0"]?.map(\.value), [34])
    }

    @MainActor
    func testUnknownSessionCreationFailureKeepsExternalDetail() async {
        let collector = ServerStatsCollector(
            dependencies: ServerStatsCollectorDependencies(
                makeOwnedConnection: { StatsTestConnection() },
                makeSession: { _, _, _ in throw StatsExternalTestError() },
                makeAttemptID: UUID.init
            )
        )

        await collector.startCollecting(for: StatsTestTarget())

        XCTAssertEqual(
            collector.collectionState.phase,
            .failed(.external(detail: "External stats failure."))
        )
    }

    @MainActor
    func testLiveApprovalErrorsMapToSemanticFailures() async {
        let cases: [(
            error: ServerSecurityApprovalError,
            failure: ServerStatsCollectionFailure
        )] = [
            (.cancelled, .securityApprovalCancelled),
            (.expired, .securityApprovalExpired),
            (.unavailable, .securityApprovalUnavailable)
        ]

        for testCase in cases {
            let target = StatsTestTarget()
            let request = makeHostKeyRequest()
            let reference = LiveServerStatsApprovalReference(
                request,
                serverID: target.serverID
            )
            let collector = ServerStatsCollector(
                dependencies: ServerStatsCollectorDependencies(
                    makeOwnedConnection: { StatsTestConnection() },
                    makeSession: { _, _, _ in
                        throw ServerStatsApprovalRequired(reference: reference)
                    },
                    makeAttemptID: UUID.init
                )
            )

            await collector.startCollecting(for: target)
            collector.resolveSecurityApproval(request, error: testCase.error)

            XCTAssertEqual(
                collector.collectionState.phase,
                .failed(testCase.failure)
            )
            XCTAssertNil(collector.approvalReferenceForPresentation)
        }
    }

    @MainActor
    func testPreparationApprovalKeepsTypedRequestWithoutStartingConnectionTask() async {
        let target = StatsTestTarget()
        let request = ServerStatsApprovalRequest(
            id: "host-key:\(target.serverID.uuidString)",
            serverID: target.serverID
        )
        let reference = StatsTestApprovalReference(request: request)
        let collector = ServerStatsCollector(
            dependencies: ServerStatsCollectorDependencies(
                makeOwnedConnection: { StatsTestConnection() },
                makeSession: { _, _, _ in
                    throw ServerStatsApprovalRequired(reference: reference)
                },
                makeAttemptID: UUID.init
            )
        )

        await collector.startCollecting(for: target)

        XCTAssertEqual(collector.collectionState.phase, .approvalRequired(request))
        XCTAssertTrue(collector.approvalReferenceForPresentation === reference)
        XCTAssertFalse(collector.isCollecting)

        collector.resolveSecurityApproval(request)
        XCTAssertEqual(collector.collectionState.phase, .idle)
    }

    @MainActor
    func testRepeatedOwnedStartKeepsOneAttemptAndUpdatesDockerPolicy() async throws {
        let runGate = StatsTestGate<Void>()
        let factory = StatsTestSessionFactory(behaviors: [.suspended(runGate)])
        let collector = makeCollector(factory: factory)
        let target = StatsTestTarget()

        await collector.startCollecting(for: target, collectDocker: false)
        let session = try XCTUnwrap(factory.sessions.first)
        await session.runStarted.wait()
        let attemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)

        await collector.startCollecting(for: target, collectDocker: true)

        XCTAssertEqual(collector.collectionState.phase.attemptID, attemptID)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.ownedConnections.count, 1)
        XCTAssertTrue(collector.isDockerCollectionEnabled)

        collector.stopCollecting()
        await runGate.waitUntilCancelled()
        await session.disconnected.wait()
        XCTAssertEqual(session.disconnectCount, 1)
    }

    @MainActor
    func testPauseAndResumeKeepSessionCacheAndSuspendPolling() async throws {
        let snapshotGate = StatsTestGate<ServerStats>()
        let firstPollWait = StatsTestGate<Void>()
        let secondPollWait = StatsTestGate<Void>()
        var pollWaits = [firstPollWait, secondPollWait]
        let factory = StatsTestSessionFactory(behaviors: [.collect(snapshotGate)])
        let collector = makeCollector(
            factory: factory,
            waitForNextPoll: {
                guard !pollWaits.isEmpty else {
                    try await Task.sleep(for: .seconds(60))
                    return
                }
                try await pollWaits.removeFirst().wait()
            }
        )
        let target = StatsTestTarget()

        await collector.startCollecting(for: target)
        let session = try XCTUnwrap(factory.sessions.first)
        await session.collectionStarted.wait()

        var snapshot = ServerStats()
        snapshot.cpuUsage = 42
        snapshotGate.succeed(with: snapshot)
        await firstPollWait.waitUntilStarted()
        let attemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)

        collector.pauseCollecting()
        XCTAssertEqual(collector.collectionState.phase, .paused(attemptID: attemptID))
        XCTAssertFalse(collector.isCollecting)
        XCTAssertEqual(collector.stats.cpuUsage, 42)

        firstPollWait.succeed(with: ())
        await secondPollWait.waitUntilStarted()
        XCTAssertEqual(session.collectionStarted.recordedCount, 1)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.ownedConnections.count, 1)

        await collector.startCollecting(for: target)
        XCTAssertTrue(collector.isCollecting)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.ownedConnections.count, 1)
        XCTAssertEqual(collector.stats.cpuUsage, 42)

        secondPollWait.succeed(with: ())
        await session.collectionStarted.wait(for: 2)
        XCTAssertEqual(session.collectionStarted.recordedCount, 2)

        collector.stopCollecting()
        await snapshotGate.waitUntilCancelled()
        await session.disconnected.wait()
        XCTAssertEqual(session.disconnectCount, 1)
    }

    @MainActor
    func testRuntimeStoreRetainsOneCollectorPerServerUntilRelease() {
        var collectorCount = 0
        let store = ServerStatsRuntimeStore {
            collectorCount += 1
            return ServerStatsCollector(
                dependencies: ServerStatsCollectorDependencies(
                    makeOwnedConnection: { StatsTestConnection() },
                    makeSession: { _, _, _ in throw StatsTestError.incompatibleConnection },
                    makeAttemptID: UUID.init
                )
            )
        }
        let firstServerID = UUID()
        let secondServerID = UUID()

        let first = store.collector(for: firstServerID)
        let repeatedFirst = store.collector(for: firstServerID)
        let second = store.collector(for: secondServerID)

        XCTAssertTrue(first === repeatedFirst)
        XCTAssertFalse(first === second)
        XCTAssertEqual(collectorCount, 2)

        store.releaseCollector(for: firstServerID)
        let replacementFirst = store.collector(for: firstServerID)

        XCTAssertFalse(first === replacementFirst)
        XCTAssertEqual(collectorCount, 3)
    }

    @MainActor
    func testRuntimeStoreReleaseStopsOwnedSessionExactlyOnce() async throws {
        let runGate = StatsTestGate<Void>()
        let factory = StatsTestSessionFactory(behaviors: [.suspended(runGate)])
        let store = ServerStatsRuntimeStore {
            self.makeCollector(factory: factory)
        }
        let serverID = UUID()
        let collector = store.collector(for: serverID)

        await collector.startCollecting(for: StatsTestTarget(serverID: serverID))
        let session = try XCTUnwrap(factory.sessions.first)
        await session.runStarted.wait()

        store.releaseCollector(for: serverID)
        store.releaseCollector(for: serverID)

        await runGate.waitUntilCancelled()
        await session.disconnected.wait()
        XCTAssertEqual(session.disconnectCount, 1)
    }

    @MainActor
    func testReplacementCancelsFirstAttemptAndRejectsItsLateSnapshot() async throws {
        let staleSnapshotGate = StatsTestGate<ServerStats>(ignoresCancellation: true)
        let replacementGate = StatsTestGate<Void>()
        let factory = StatsTestSessionFactory(behaviors: [
            .collect(staleSnapshotGate),
            .suspended(replacementGate)
        ])
        let repeatedAttemptID = UUID()
        let collector = makeCollector(
            factory: factory,
            makeAttemptID: { repeatedAttemptID }
        )
        let target = StatsTestTarget()
        let firstConnection = StatsTestConnection()
        let replacementConnection = StatsTestConnection()

        await collector.startCollecting(for: target, using: firstConnection)
        let firstSession = try XCTUnwrap(factory.sessions.first)
        await staleSnapshotGate.waitUntilStarted()

        await collector.startCollecting(for: target, using: replacementConnection)
        let replacementSession = try XCTUnwrap(factory.sessions.last)
        await staleSnapshotGate.waitUntilCancelled()
        await replacementSession.runStarted.wait()
        let replacementAttemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)
        XCTAssertEqual(replacementAttemptID, repeatedAttemptID)

        var staleStats = ServerStats()
        staleStats.cpuUsage = 91
        staleSnapshotGate.succeed(with: staleStats)
        await firstSession.runFinished.wait()

        XCTAssertEqual(
            collector.collectionState.phase,
            .starting(attemptID: replacementAttemptID)
        )
        XCTAssertEqual(collector.stats.cpuUsage, 0)

        collector.stopCollecting()
        await replacementGate.waitUntilCancelled()
    }

    @MainActor
    func testOwnerReleaseCancelsActiveConnectionTask() async throws {
        let runGate = StatsTestGate<Void>()
        let factory = StatsTestSessionFactory(behaviors: [.suspended(runGate)])
        weak var releasedCollector: ServerStatsCollector?

        do {
            let collector = makeCollector(factory: factory)
            releasedCollector = collector
            await collector.startCollecting(for: StatsTestTarget())
            let session = try XCTUnwrap(factory.sessions.first)
            await session.runStarted.wait()
        }

        await runGate.waitUntilCancelled()
        XCTAssertNil(releasedCollector)
    }

    @MainActor
    func testStopCancelsUserOperationAndRejectsCancellationIgnoringResult() async throws {
        let factory = StatsTestSessionFactory(behaviors: [.collect(nil)])
        let collector = makeCollector(factory: factory)
        let sessionTarget = StatsTestTarget()
        let connection = StatsTestConnection()

        await collector.startCollecting(for: sessionTarget, using: connection)
        let session = try XCTUnwrap(factory.sessions.first)
        await session.collectionStarted.wait()

        let dockerGate = StatsTestGate<DockerStats>(ignoresCancellation: true)
        session.dockerGate = dockerGate
        let operation = Task { @MainActor in
            try await collector.loadDockerStats()
        }
        await dockerGate.waitUntilStarted()

        collector.stopCollecting()
        await dockerGate.waitUntilCancelled()

        let staleDocker = DockerStats(
            availability: .available,
            containers: [],
            timestamp: Date(timeIntervalSince1970: 123)
        )
        dockerGate.succeed(with: staleDocker)

        do {
            _ = try await operation.value
            XCTFail("A stale operation must not return a result")
        } catch {
            // The attempt was invalidated before the cancellation-ignoring result returned.
        }
        XCTAssertNotEqual(collector.stats.docker, staleDocker)
    }

    @MainActor
    func testIndependentCollectorsDoNotShareAttemptOrCancellation() async throws {
        let firstGate = StatsTestGate<Void>()
        let secondGate = StatsTestGate<Void>()
        let firstFactory = StatsTestSessionFactory(behaviors: [.suspended(firstGate)])
        let secondFactory = StatsTestSessionFactory(behaviors: [.suspended(secondGate)])
        let firstCollector = makeCollector(factory: firstFactory)
        let secondCollector = makeCollector(factory: secondFactory)

        await firstCollector.startCollecting(for: StatsTestTarget())
        await secondCollector.startCollecting(for: StatsTestTarget())
        let firstSession = try XCTUnwrap(firstFactory.sessions.first)
        let secondSession = try XCTUnwrap(secondFactory.sessions.first)
        await firstSession.runStarted.wait()
        await secondSession.runStarted.wait()

        firstCollector.stopCollecting()
        await firstGate.waitUntilCancelled()

        XCTAssertTrue(secondCollector.isCollecting)
        XCTAssertNotEqual(
            firstSession.connectionIdentity,
            secondSession.connectionIdentity
        )

        secondCollector.stopCollecting()
        await secondGate.waitUntilCancelled()
    }

    @MainActor
    private func makeCollector(
        factory: StatsTestSessionFactory,
        makeAttemptID: @escaping () -> UUID = UUID.init,
        waitForNextPoll: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(2))
        }
    ) -> ServerStatsCollector {
        ServerStatsCollector(
            dependencies: ServerStatsCollectorDependencies(
                makeOwnedConnection: { factory.makeOwnedConnection() },
                makeSession: { target, connection, ownership in
                    try factory.makeSession(
                        target: target,
                        connection: connection,
                        ownership: ownership
                    )
                },
                makeAttemptID: makeAttemptID,
                waitForNextPoll: waitForNextPoll
            )
        )
    }

    private func makeHostKeyRequest() -> ServerSecurityApprovalRequest {
        .hostKey(
            KnownHostsManager.Challenge(
                id: UUID(),
                host: "stats.example.test",
                port: 22,
                fingerprint: "SHA256:test",
                keyType: 1,
                keyTypeName: "ssh-ed25519",
                kind: .firstUse,
                createdAt: .distantPast
            )
        )
    }
}
