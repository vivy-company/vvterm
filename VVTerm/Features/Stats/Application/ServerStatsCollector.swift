import Combine
import Foundation
import os.log

nonisolated enum ServerStatsCollectionFailure: Equatable, Sendable {
    case securityApprovalCancelled
    case securityApprovalExpired
    case securityApprovalUnavailable
    case external(detail: String)
}

nonisolated struct ServerStatsCollectionState: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case starting(attemptID: UUID)
        case startingPaused(attemptID: UUID)
        case collecting(attemptID: UUID)
        case paused(attemptID: UUID)
        case approvalRequired(ServerStatsApprovalRequest)
        case failed(ServerStatsCollectionFailure)

        var attemptID: UUID? {
            switch self {
            case .starting(let attemptID),
                 .startingPaused(let attemptID),
                 .collecting(let attemptID),
                 .paused(let attemptID):
                return attemptID
            case .idle, .approvalRequired, .failed:
                return nil
            }
        }
    }

    private(set) var phase: Phase = .idle

    var isCollecting: Bool {
        switch phase {
        case .starting, .collecting:
            return true
        case .idle, .startingPaused, .paused, .approvalRequired, .failed:
            return false
        }
    }

    var isPolling: Bool {
        if case .collecting = phase { return true }
        return false
    }

    var approvalRequest: ServerStatsApprovalRequest? {
        guard case .approvalRequired(let request) = phase else { return nil }
        return request
    }

    mutating func start(attemptID: UUID) {
        phase = .starting(attemptID: attemptID)
    }

    @discardableResult
    mutating func markConnected(attemptID: UUID) -> Bool {
        switch phase {
        case .starting(let currentAttemptID) where currentAttemptID == attemptID:
            phase = .collecting(attemptID: attemptID)
            return true
        case .startingPaused(let currentAttemptID) where currentAttemptID == attemptID:
            phase = .paused(attemptID: attemptID)
            return true
        default:
            return false
        }
    }

    @discardableResult
    mutating func pause(attemptID: UUID) -> Bool {
        switch phase {
        case .starting(let currentAttemptID) where currentAttemptID == attemptID:
            phase = .startingPaused(attemptID: attemptID)
            return true
        case .collecting(let currentAttemptID) where currentAttemptID == attemptID:
            phase = .paused(attemptID: attemptID)
            return true
        case .startingPaused(let currentAttemptID) where currentAttemptID == attemptID:
            return true
        case .paused(let currentAttemptID) where currentAttemptID == attemptID:
            return true
        default:
            return false
        }
    }

    @discardableResult
    mutating func resume(attemptID: UUID) -> Bool {
        switch phase {
        case .startingPaused(let currentAttemptID) where currentAttemptID == attemptID:
            phase = .starting(attemptID: attemptID)
            return true
        case .paused(let currentAttemptID) where currentAttemptID == attemptID:
            phase = .collecting(attemptID: attemptID)
            return true
        case .starting(let currentAttemptID) where currentAttemptID == attemptID:
            return true
        case .collecting(let currentAttemptID) where currentAttemptID == attemptID:
            return true
        default:
            return false
        }
    }

    @discardableResult
    mutating func finish(
        attemptID: UUID,
        failure: ServerStatsCollectionFailure? = nil
    ) -> Bool {
        guard phase.attemptID == attemptID else { return false }
        if let failure {
            phase = .failed(failure)
        } else {
            phase = .idle
        }
        return true
    }

    mutating func stop() {
        phase = .idle
    }

    @discardableResult
    mutating func requireApproval(
        attemptID: UUID,
        request: ServerStatsApprovalRequest
    ) -> Bool {
        guard phase.attemptID == attemptID else { return false }
        phase = .approvalRequired(request)
        return true
    }

    @discardableResult
    mutating func resolveApproval(
        _ request: ServerStatsApprovalRequest,
        failure: ServerStatsCollectionFailure? = nil
    ) -> Bool {
        guard phase == .approvalRequired(request) else { return false }
        if let failure {
            phase = .failed(failure)
        } else {
            phase = .idle
        }
        return true
    }
}

/// Coordinates one stats collection attempt without owning transport details.
@MainActor
final class ServerStatsCollector: ObservableObject {
    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var networkRxHistory: [StatsPoint] = []
    @Published var networkTxHistory: [StatsPoint] = []
    @Published var gpuUtilizationHistoryByDeviceID: [String: [StatsPoint]] = [:]
    @Published var dockerCPUHistory: [StatsPoint] = []
    @Published var dockerMemoryHistory: [StatsPoint] = []
    @Published private(set) var collectionState = ServerStatsCollectionState()

    private let logger = Logger(subsystem: "app.vivy.vvterm", category: "Stats")
    private let dependencies: ServerStatsCollectorDependencies

    private struct CollectionIdentity: Equatable {
        let serverID: UUID
        let connectionID: ServerStatsConnectionIdentity
        let ownership: ServerStatsClientOwnership
    }

    private final class AttemptIdentity: Sendable {}

    @MainActor
    private final class CollectionAttempt {
        let id: UUID
        let attemptIdentity = AttemptIdentity()
        let serverID: UUID
        let session: any ServerStatsCollectionSession
        let identity: CollectionIdentity
        var collectDocker: Bool
        var primaryTask: Task<Void, Never>?
        var operationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

        init(
            id: UUID,
            serverID: UUID,
            session: any ServerStatsCollectionSession,
            collectDocker: Bool
        ) {
            self.id = id
            self.serverID = serverID
            self.session = session
            self.identity = CollectionIdentity(
                serverID: serverID,
                connectionID: session.connectionIdentity,
                ownership: session.ownership
            )
            self.collectDocker = collectDocker
        }

        func cancelAllTasks() {
            primaryTask?.cancel()
            primaryTask = nil
            let tasks = Array(operationTasks.values)
            operationTasks.removeAll()
            tasks.forEach { $0.cancel() }
        }
    }

    @MainActor
    private final class TrackedOperationResult<Output> {
        var value: Result<Output, Error>?

        #if compiler(<6.4)
        // Xcode 26.5 crashes while optimizing the isolated destructor of a
        // generic MainActor class. Xcode 27 fixes the compiler bug.
        @_optimize(none)
        deinit {}
        #endif
    }

    private var activeAttempt: CollectionAttempt?
    private var pendingApprovalReference: (any ServerStatsApprovalReference)?
    private var cleanupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    var isCollecting: Bool { collectionState.isCollecting }
    var isDockerCollectionEnabled: Bool { activeAttempt?.collectDocker ?? false }

    var presentationSnapshot: ServerStatsPresentationSnapshot {
        ServerStatsPresentationSnapshot(
            stats: stats,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            gpuHistories: gpuUtilizationHistoryByDeviceID,
            networkRxHistory: networkRxHistory,
            networkTxHistory: networkTxHistory,
            dockerCPUHistory: dockerCPUHistory,
            dockerMemoryHistory: dockerMemoryHistory
        )
    }

    var approvalReferenceForPresentation: (any ServerStatsApprovalReference)? {
        pendingApprovalReference
    }

    init(dependencies: ServerStatsCollectorDependencies) {
        self.dependencies = dependencies
    }

    isolated deinit {
        activeAttempt?.primaryTask?.cancel()
        activeAttempt?.operationTasks.values.forEach { $0.cancel() }
        cleanupTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Collection Control

    func startCollecting(
        for target: any ServerStatsCollectionTarget,
        using sharedConnection: (any ServerStatsConnectionReference)? = nil,
        collectDocker: Bool = false
    ) async {
        let ownership: ServerStatsClientOwnership = sharedConnection == nil
            ? .owned
            : .shared

        if sharedConnection == nil,
           let activeAttempt,
           activeAttempt.serverID == target.serverID,
           activeAttempt.identity.ownership == .owned {
            activeAttempt.collectDocker = collectDocker
            _ = collectionState.resume(attemptID: activeAttempt.id)
            return
        }

        let connection = sharedConnection ?? dependencies.makeOwnedConnection()
        let requestedIdentity = CollectionIdentity(
            serverID: target.serverID,
            connectionID: connection.identity,
            ownership: ownership
        )
        if let activeAttempt, activeAttempt.identity == requestedIdentity {
            activeAttempt.collectDocker = collectDocker
            _ = collectionState.resume(attemptID: activeAttempt.id)
            return
        }

        supersedeActiveAttempt()
        pendingApprovalReference = nil

        let attemptID = dependencies.makeAttemptID()
        collectionState.start(attemptID: attemptID)
        resetCollectionState()

        let session: any ServerStatsCollectionSession
        do {
            session = try dependencies.makeSession(target, connection, ownership)
        } catch let approval as ServerStatsApprovalRequired {
            requireApproval(attemptID: attemptID, reference: approval.reference)
            return
        } catch {
            _ = collectionState.finish(
                attemptID: attemptID,
                failure: .external(detail: error.localizedDescription)
            )
            return
        }

        let attempt = CollectionAttempt(
            id: attemptID,
            serverID: target.serverID,
            session: session,
            collectDocker: collectDocker
        )
        activeAttempt = attempt
        let attemptIdentity = attempt.attemptIdentity

        let collectConnection: @MainActor @Sendable () async throws -> Void = { [weak self] in
            guard self?.markCollectionConnected(
                attemptID: attemptID,
                attemptIdentity: attemptIdentity
            ) == true else { return }

            while !Task.isCancelled {
                guard self?.isCurrentCollectionAttempt(attemptIdentity) == true else { return }
                if self?.collectionState.isPolling == true {
                    await self?.collectStats(attemptIdentity: attemptIdentity)
                }
                try await self?.dependencies.waitForNextPoll()
            }
        }
        let task = Task(priority: .utility) { @MainActor [weak self, session] in
            do {
                try await session.runCollection(collectConnection)
                self?.finishCollection(
                    attemptID: attemptID,
                    attemptIdentity: attemptIdentity
                )
            } catch is CancellationError {
                // Stop and replacement already invalidated this attempt.
            } catch let approval as ServerStatsApprovalRequired {
                self?.requireApproval(
                    attemptID: attemptID,
                    attemptIdentity: attemptIdentity,
                    reference: approval.reference
                )
            } catch {
                self?.finishCollection(
                    attemptID: attemptID,
                    attemptIdentity: attemptIdentity,
                    failure: .external(detail: error.localizedDescription)
                )
            }
        }
        attempt.primaryTask = task
    }

    func pauseCollecting() {
        guard let activeAttempt else { return }
        _ = collectionState.pause(attemptID: activeAttempt.id)
    }

    func stopCollecting() {
        pendingApprovalReference = nil
        guard let attempt = activeAttempt else {
            collectionState.stop()
            return
        }

        activeAttempt = nil
        collectionState.stop()
        cancel(attempt)
    }

    func resolveSecurityApproval(
        _ request: ServerStatsApprovalRequest,
        failure: ServerStatsCollectionFailure? = nil
    ) {
        guard collectionState.resolveApproval(request, failure: failure) else { return }
        pendingApprovalReference = nil
    }

    // MARK: - User-Initiated Operations

    func terminateProcess(_ process: ProcessInfo) async throws {
        guard process.pid > 1 else {
            throw ProcessControlError.protectedProcess
        }
        let attempt = try requireActiveAttempt()
        let refresh: (
            stats: ServerStats?,
            failure: ServerStatsCollectionFailure?
        ) = try await performTrackedOperation(for: attempt) { session in
            try await session.terminateProcess(process)
            do {
                let stats = try await session.collectStats(
                    collectDocker: attempt.collectDocker
                )
                return (stats, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (nil, .external(detail: error.localizedDescription))
            }
        }
        if let collectedStats = refresh.stats {
            applyCollectedSnapshot(collectedStats)
        } else if let failure = refresh.failure {
            finishCollection(
                attemptID: attempt.id,
                attemptIdentity: attempt.attemptIdentity,
                failure: failure
            )
        }
    }

    func loadProcesses() async throws -> [ProcessInfo] {
        let attempt = try requireActiveAttempt()
        let fallback = stats.topProcesses
        return try await performTrackedOperation(for: attempt) { session in
            try await session.loadProcesses(fallback: fallback)
        }
    }

    func loadDockerStats() async throws -> DockerStats {
        let attempt = try requireActiveAttempt()
        let fallback = stats.docker
        let dockerStats = try await performTrackedOperation(for: attempt) { session in
            await session.loadDockerStats(fallback: fallback)
        }
        stats.docker = dockerStats
        return dockerStats
    }

    func loadStorageHealth(for volume: VolumeInfo) async throws -> StorageHealthResult {
        let attempt = try requireActiveAttempt()
        guard let currentVolume = VolumeVisibilityPolicy.normalized(stats.volumes)
            .first(where: { $0.identity == volume.identity }) else {
            return .unavailable(.unmapped)
        }
        return try await performTrackedOperation(for: attempt) { session in
            try await session.loadStorageHealth(for: currentVolume)
        }
    }

    func performDockerAction(
        _ action: DockerContainerAction,
        on container: DockerContainer
    ) async throws -> DockerStats {
        let attempt = try requireActiveAttempt()
        let fallback = stats.docker
        let dockerStats = try await performTrackedOperation(for: attempt) { session in
            try await session.performDockerAction(
                action,
                on: container,
                fallback: fallback
            )
        }
        stats.docker = dockerStats
        return dockerStats
    }

    // MARK: - Attempt Ownership

    private func requireActiveAttempt() throws -> CollectionAttempt {
        guard let activeAttempt else { throw ProcessControlError.notConnected }
        return activeAttempt
    }

    private func performTrackedOperation<Output>(
        for attempt: CollectionAttempt,
        operation: @MainActor @escaping (any ServerStatsCollectionSession) async throws -> Output
    ) async throws -> Output {
        guard isCurrentCollectionAttempt(attempt.attemptIdentity) else {
            throw ProcessControlError.notConnected
        }

        let result = TrackedOperationResult<Output>()
        let operationID = ObjectIdentifier(result)
        let task = Task { @MainActor in
            do {
                result.value = .success(try await operation(attempt.session))
            } catch {
                result.value = .failure(error)
            }
        }
        attempt.operationTasks[operationID] = task
        defer { attempt.operationTasks.removeValue(forKey: operationID) }

        await task.value
        guard isCurrentCollectionAttempt(attempt.attemptIdentity) else {
            throw ProcessControlError.notConnected
        }
        guard let value = result.value else {
            throw CancellationError()
        }
        return try value.get()
    }

    private func supersedeActiveAttempt() {
        guard let attempt = activeAttempt else { return }
        activeAttempt = nil
        cancel(attempt)
    }

    private func cancel(_ attempt: CollectionAttempt) {
        attempt.cancelAllTasks()
        guard attempt.identity.ownership == .owned else { return }

        let cleanupID = ObjectIdentifier(attempt.attemptIdentity)
        let session = attempt.session
        let task = Task { @MainActor [weak self, session] in
            await session.disconnect()
            self?.cleanupTasks.removeValue(forKey: cleanupID)
        }
        cleanupTasks[cleanupID] = task
    }

    private func currentCollectionAttempt(
        _ attemptIdentity: AttemptIdentity
    ) -> CollectionAttempt? {
        guard activeAttempt?.attemptIdentity === attemptIdentity else { return nil }
        return activeAttempt
    }

    private func isCurrentCollectionAttempt(_ attemptIdentity: AttemptIdentity) -> Bool {
        activeAttempt?.attemptIdentity === attemptIdentity
    }

    private func markCollectionConnected(
        attemptID: UUID,
        attemptIdentity: AttemptIdentity
    ) -> Bool {
        guard currentCollectionAttempt(attemptIdentity) != nil else { return false }
        return collectionState.markConnected(attemptID: attemptID)
    }

    private func finishCollection(
        attemptID: UUID,
        attemptIdentity: AttemptIdentity,
        failure: ServerStatsCollectionFailure? = nil
    ) {
        guard let attempt = currentCollectionAttempt(attemptIdentity),
              collectionState.finish(attemptID: attemptID, failure: failure) else { return }
        activeAttempt = nil
        cancel(attempt)
    }

    private func requireApproval(
        attemptID: UUID,
        attemptIdentity: AttemptIdentity? = nil,
        reference: any ServerStatsApprovalReference
    ) {
        if let attemptIdentity,
           currentCollectionAttempt(attemptIdentity) == nil {
            return
        }
        guard collectionState.requireApproval(
            attemptID: attemptID,
            request: reference.request
        ) else { return }
        let attempt = attemptIdentity.flatMap(currentCollectionAttempt)
        activeAttempt = nil
        if let attempt {
            cancel(attempt)
        }
        pendingApprovalReference = reference
    }

    // MARK: - Stats Collection

    private func collectStats(attemptIdentity: AttemptIdentity) async {
        guard let attempt = currentCollectionAttempt(attemptIdentity) else { return }

        do {
            if let preparation = await attempt.session.prepareIfNeeded() {
                guard currentCollectionAttempt(attemptIdentity) != nil else { return }
                logger.info("Detected remote platform: \(preparation.platformName)")
                applyProfile(preparation.profile)
            }

            let collectedStats = try await attempt.session.collectStats(
                collectDocker: attempt.collectDocker
            )
            guard currentCollectionAttempt(attemptIdentity) != nil else { return }
            applyCollectedSnapshot(collectedStats)
        } catch is CancellationError {
            return
        } catch {
            guard currentCollectionAttempt(attemptIdentity) != nil else { return }
            logger.error("Failed to collect stats: \(error.localizedDescription)")
            finishCollection(
                attemptID: attempt.id,
                attemptIdentity: attemptIdentity,
                failure: .external(detail: error.localizedDescription)
            )
        }
    }

    private func resetCollectionState() {
        cpuHistory = []
        memoryHistory = []
        networkRxHistory = []
        networkTxHistory = []
        gpuUtilizationHistoryByDeviceID = [:]
        dockerCPUHistory = []
        dockerMemoryHistory = []
    }

    private func applyProfile(_ profile: HardwareProfile?) {
        let hardwareProfile = profile ?? .empty
        stats.hardware = hardwareProfile
        stats.hostname = hardwareProfile.hostname
        stats.osInfo = hardwareProfile.osInfo
        let profileCPUCount = hardwareProfile.cpuThreads > 0
            ? hardwareProfile.cpuThreads
            : hardwareProfile.cpuCores
        if profileCPUCount > 0 {
            stats.cpuCores = profileCPUCount
        }
        if stats.memoryTotal == 0 {
            stats.memoryTotal = hardwareProfile.memoryTotal
        }
    }

    private func applyCollectedSnapshot(_ collectedStats: ServerStats) {
        var newStats = collectedStats
        let existingStats = stats
        let collectedCPUCoreCount = newStats.cpuCores
        newStats.hostname = existingStats.hostname
        newStats.osInfo = existingStats.osInfo
        newStats.cpuCores = Self.resolvedCPUCoreCount(
            existing: existingStats.cpuCores,
            collected: collectedCPUCoreCount
        )
        newStats.hardware = existingStats.hardware
        if newStats.gpuSamples.isEmpty, !existingStats.gpuSamples.isEmpty {
            newStats.gpuSamples = existingStats.gpuSamples
        }
        applyCollectedStats(newStats)
    }

    private func applyCollectedStats(_ newStats: ServerStats) {
        stats = newStats

        cpuHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.cpuUsage))
        memoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.memoryPercent))
        networkRxHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.networkRxSpeed)))
        networkTxHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.networkTxSpeed)))
        dockerCPUHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.docker.aggregateCPUPercent))
        dockerMemoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.docker.memoryPercent))
        appendGPUHistory(from: newStats)

        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if memoryHistory.count > 60 { memoryHistory.removeFirst() }
        if networkRxHistory.count > 60 { networkRxHistory.removeFirst() }
        if networkTxHistory.count > 60 { networkTxHistory.removeFirst() }
        if dockerCPUHistory.count > 60 { dockerCPUHistory.removeFirst() }
        if dockerMemoryHistory.count > 60 { dockerMemoryHistory.removeFirst() }
    }

    private func appendGPUHistory(from newStats: ServerStats) {
        for sample in newStats.gpuSamples {
            guard let utilization = sample.utilizationPercent else { continue }
            var history = gpuUtilizationHistoryByDeviceID[sample.deviceID] ?? []
            history.append(StatsPoint(timestamp: newStats.timestamp, value: utilization))
            if history.count > 60 {
                history.removeFirst(history.count - 60)
            }
            gpuUtilizationHistoryByDeviceID[sample.deviceID] = history
        }
    }

    nonisolated static func resolvedCPUCoreCount(existing: Int, collected: Int) -> Int {
        if existing > 0, collected > 0 {
            return max(existing, collected)
        }
        if existing > 0 {
            return existing
        }
        return max(collected, 0)
    }
}

nonisolated enum ProcessControlError: Error, Equatable, Sendable {
    case notConnected
    case protectedProcess
}
