import CloudKit
import Foundation
import os.log

@MainActor
extension CloudKitManager {
    // MARK: - Account Status

    /// Ensures account status is checked before performing operations
    func ensureAccountStatusChecked(for generation: UUID) async throws {
        try requireCurrentGeneration(generation)
        guard !isAvailable else { return }
        await checkAccountStatus(for: generation)
        try requireCurrentGeneration(generation)
    }

    func checkAccountStatus(for generation: UUID) async {
        guard isCurrentGeneration(generation) else { return }

        let check: AccountStatusCheck
        if let current = accountStatusCheck, current.generation == generation {
            check = current
        } else {
            let task = Task { @MainActor [fetchAccountStatus] in
                let status = try await fetchAccountStatus()
                try Task.checkCancellation()
                return status
            }
            check = AccountStatusCheck(
                id: UUID(),
                generation: generation,
                task: task
            )
            accountStatusCheck = check
        }

        do {
            let status = try await check.task.value
            guard isCurrentGeneration(generation),
                  accountStatusCheck?.id == check.id else {
                return
            }
            accountStatusCheck = nil
            let resolvedAccountState: CloudKitAccountState = switch status {
            case .available:
                .available
            case .noAccount:
                .noAccount
            case .restricted:
                .restricted
            case .couldNotDetermine:
                .couldNotDetermine
            case .temporarilyUnavailable:
                .temporarilyUnavailable
            @unknown default:
                .unknown(rawValue: status.rawValue)
            }
            let statusLogValue = String(describing: resolvedAccountState)

            logger.info("CloudKit account status: \(statusLogValue)")
            logger.info("Container identifier: \(self.container.containerIdentifier ?? "nil")")

            statusStore.accountState = resolvedAccountState
            if status == .available {
                statusStore.syncState.markAvailable()
            } else {
                statusStore.syncState.markOffline()
                logger.warning("CloudKit not available. Status: \(statusLogValue)")
            }
        } catch {
            guard isCurrentGeneration(generation),
                  accountStatusCheck?.id == check.id else {
                return
            }
            accountStatusCheck = nil
            if error is CancellationError { return }
            logger.error("CloudKit account status check failed: \(error.localizedDescription)")
            statusStore.accountState = .failed(detail: error.localizedDescription)
            statusStore.syncState.markAccountFailure(error.localizedDescription)
        }
    }

    func applySyncDisabledState() {
        statusStore.syncState.markDisabled()
        statusStore.accountState = .disabled
    }

    func handleSyncToggle(_ enabled: Bool) {
        let generation = advanceSyncGeneration()
        if enabled {
            statusStore.accountState = .checking
            statusStore.syncState.markCheckingAccount()
            Task { [weak self] in
                guard let self else { return }
                await self.checkAccountStatus(for: generation)
                await self.subscribeToChanges(generation: generation)
            }
        } else {
            applySyncDisabledState()
        }
    }
}
