import CloudKit
import Foundation
import os.log

@MainActor
extension CloudKitManager {
    // MARK: - Change Fetching (Incremental, No Queries)

    func fetchCloudKitRecordChanges(
        forceFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> CloudKitRawRecordChanges {
        let generation = cloudKitSyncGeneration
        try Task.checkCancellation()
        try await ensureAccountStatusChecked(for: generation)
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()
        try requireCurrentGeneration(generation)

        let fetchIdentity = CloudKitRecordChangeFetchIdentity(
            forceFullFetch: forceFullFetch,
            desiredKeys: desiredKeys
        )
        if let pendingRecordChanges {
            _ = try CloudKitRecordChangeRequestPolicy.decision(
                for: fetchIdentity,
                inFlight: pendingRecordChanges.identity
            )
            try Task.checkCancellation()
            return pendingRecordChanges.changes
        }
        let requestDecision = try CloudKitRecordChangeRequestPolicy.decision(
            for: fetchIdentity,
            inFlight: inFlightRecordChanges?.identity
        )
        if requestDecision == .coalesce, let inFlightRecordChanges {
            if CloudKitRecordChangeRequestPolicy.requiresCancellationTeardown(
                activeWaiterCount: inFlightRecordChanges.waiters.count
            ) {
                let teardownWaiterID = UUID()
                let teardownWaiter = CloudKitTaskContinuation<Void>()
                self.inFlightRecordChanges?.teardownWaiters[teardownWaiterID] = teardownWaiter
                try await awaitRecordChangesTeardown(
                    taskID: inFlightRecordChanges.id,
                    waiterID: teardownWaiterID,
                    waiter: teardownWaiter
                )
                return try await fetchCloudKitRecordChanges(
                    forceFullFetch: forceFullFetch,
                    desiredKeys: desiredKeys
                )
            }
            let waiterID = UUID()
            let waiter = CloudKitTaskContinuation<CloudKitRawRecordChanges>()
            self.inFlightRecordChanges?.waiters[waiterID] = waiter
            return try await awaitRecordChanges(
                taskID: inFlightRecordChanges.id,
                waiterID: waiterID,
                waiter: waiter
            )
        }

        let taskID = UUID()
        let waiterID = UUID()
        let waiter = CloudKitTaskContinuation<CloudKitRawRecordChanges>()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let changes = try await self.withZoneRetry {
                    try await self.fetchRecordChangesFromCloudKit(
                        forceFullFetch: forceFullFetch,
                        desiredKeys: desiredKeys,
                        identity: fetchIdentity,
                        generation: generation
                    )
                }
                try self.requireCurrentGeneration(generation)
                self.completeRecordChangesTask(taskID, with: .success(changes))
                return changes
            } catch {
                self.completeRecordChangesTask(taskID, with: .failure(error))
                throw error
            }
        }
        inFlightRecordChanges = InFlightRecordChanges(
            id: taskID,
            identity: fetchIdentity,
            task: task,
            waiters: [waiterID: waiter],
            teardownWaiters: [:]
        )

        return try await awaitRecordChanges(
            taskID: taskID,
            waiterID: waiterID,
            waiter: waiter
        )
    }

    func awaitRecordChanges(
        taskID: UUID,
        waiterID: UUID,
        waiter: CloudKitTaskContinuation<CloudKitRawRecordChanges>
    ) async throws -> CloudKitRawRecordChanges {
        return try await withTaskCancellationHandler {
            let changes = try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
            }
            try Task.checkCancellation()
            return changes
        } onCancel: {
            waiter.cancel()
            Task { @MainActor [weak self] in
                self?.releaseRecordChangesWaiter(
                    taskID: taskID,
                    waiterID: waiterID
                )
            }
        }
    }

    func releaseRecordChangesWaiter(
        taskID: UUID,
        waiterID: UUID
    ) {
        guard var inFlightRecordChanges, inFlightRecordChanges.id == taskID else { return }
        guard inFlightRecordChanges.waiters.removeValue(forKey: waiterID) != nil else { return }
        if inFlightRecordChanges.waiters.isEmpty {
            inFlightRecordChanges.task.cancel()
        }
        self.inFlightRecordChanges = inFlightRecordChanges
    }

    func awaitRecordChangesTeardown(
        taskID: UUID,
        waiterID: UUID,
        waiter: CloudKitTaskContinuation<Void>
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            waiter.cancel()
            Task { @MainActor [weak self] in
                self?.releaseRecordChangesTeardownWaiter(
                    taskID: taskID,
                    waiterID: waiterID
                )
            }
        }
    }

    func releaseRecordChangesTeardownWaiter(
        taskID: UUID,
        waiterID: UUID
    ) {
        guard var inFlightRecordChanges, inFlightRecordChanges.id == taskID else { return }
        inFlightRecordChanges.teardownWaiters.removeValue(forKey: waiterID)
        self.inFlightRecordChanges = inFlightRecordChanges
    }

    func completeRecordChangesTask(
        _ taskID: UUID,
        with result: Result<CloudKitRawRecordChanges, Error>
    ) {
        guard let inFlightRecordChanges, inFlightRecordChanges.id == taskID else { return }
        self.inFlightRecordChanges = nil
        for waiter in inFlightRecordChanges.waiters.values {
            waiter.resume(with: result)
        }
        for waiter in inFlightRecordChanges.teardownWaiters.values {
            waiter.resume(with: .success(()))
        }
    }

    func fetchRecordChangesFromCloudKit(
        forceFullFetch: Bool,
        desiredKeys: [String],
        identity: CloudKitRecordChangeFetchIdentity,
        generation: UUID
    ) async throws -> CloudKitRawRecordChanges {
        try await performSyncOperation(generation: generation) {
            try await fetchTrackedRecordChangesFromCloudKit(
                forceFullFetch: forceFullFetch,
                desiredKeys: desiredKeys,
                identity: identity,
                generation: generation
            )
        }
    }

    func fetchTrackedRecordChangesFromCloudKit(
        forceFullFetch: Bool,
        desiredKeys: [String],
        identity: CloudKitRecordChangeFetchIdentity,
        generation: UUID
    ) async throws -> CloudKitRawRecordChanges {
        let previousToken = forceFullFetch ? nil : loadChangeToken()

        do {
            let changes = try await fetchRawRecordChangesFromCloudKit(
                previousToken: previousToken,
                isFullFetch: forceFullFetch || previousToken == nil,
                desiredKeys: desiredKeys
            )
            try requireCurrentGeneration(generation)
            logger.info(
                "Fetched \(changes.changes.count) raw CloudKit changes (full fetch: \(changes.isFullFetch))"
            )
            return makePendingRecordChanges(from: changes, identity: identity)
        } catch {
            if isChangeTokenExpired(error) {
                try requireCurrentGeneration(generation)
                logger.warning("CloudKit change token expired; resetting and performing full fetch")
                clearChangeToken()
                let changes = try await fetchRawRecordChangesFromCloudKit(
                    previousToken: nil,
                    isFullFetch: true,
                    desiredKeys: desiredKeys
                )
                try requireCurrentGeneration(generation)
                return makePendingRecordChanges(from: changes, identity: identity)
            }

            logger.error("Failed to fetch changes: \(error.localizedDescription)")
            throw error
        }
    }

    func fetchRawRecordChangesFromCloudKit(
        previousToken: CKServerChangeToken?,
        isFullFetch: Bool,
        desiredKeys: [String]
    ) async throws -> FetchedRecordChanges {
        let zoneID = recordZoneID
        var token = previousToken
        var moreComing = true

        var budget = CloudKitSyncBudget()
        var changes: [CloudKitRawRecordChange] = []

        while moreComing {
            try budget.requireCapacityForNextPage()
            let batch = try await fetchZoneChanges(
                zoneID: zoneID,
                previousToken: token,
                budget: budget,
                desiredKeys: desiredKeys
            )
            try budget.recordBatch(
                records: batch.records.count,
                deletions: batch.deletions.count,
                aggregateBytes: batch.recordByteCount
            )

            for record in batch.records {
                changes.append(.record(record))
            }

            for deletion in batch.deletions {
                changes.append(
                    .deletion(
                        recordID: deletion.recordID,
                        recordType: deletion.recordType
                    )
                )
            }

            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return FetchedRecordChanges(
            changes: changes,
            isFullFetch: isFullFetch,
            token: token
        )
    }

    func makePendingRecordChanges(
        from fetched: FetchedRecordChanges,
        identity: CloudKitRecordChangeFetchIdentity
    ) -> CloudKitRawRecordChanges {
        let changes = CloudKitRawRecordChanges(
            changes: fetched.changes,
            isFullFetch: fetched.isFullFetch,
            checkpoint: CloudKitRecordChangeCheckpoint(id: UUID())
        )
        pendingRecordChanges = PendingRecordChanges(
            identity: identity,
            changes: changes,
            token: fetched.token
        )
        return changes
    }

    func commitCloudKitRecordChanges(
        _ checkpoint: CloudKitRecordChangeCheckpoint
    ) throws {
        try CloudKitRecordChangeCheckpointPolicy.validate(
            checkpoint,
            pending: pendingRecordChanges?.changes.checkpoint
        )
        if let token = pendingRecordChanges?.token {
            try saveChangeToken(token)
        }
        pendingRecordChanges = nil
        statusStore.lastSyncDate = Date()
    }
}
