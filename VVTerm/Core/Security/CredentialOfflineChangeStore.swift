import Foundation

nonisolated enum CredentialOfflineChange: String, Codable, Equatable, Sendable {
    case unchanged
    case updated
    case deleted
}

nonisolated enum CredentialReconciliationPhase: String, Codable, Equatable, Sendable {
    case preparingOfflineSnapshot
    case remoteChanges
    case localCleanup
}

nonisolated enum CredentialSyncUnit: Hashable, Sendable {
    case server(UUID)
    case sshKey(UUID)
    case legacySSHLibrary
    case oauth(String)

    var storageKey: String {
        switch self {
        case .server(let id):
            return "server:\(id.uuidString)"
        case .sshKey(let id):
            return "ssh-key:\(id.uuidString)"
        case .legacySSHLibrary:
            return "ssh-library"
        case .oauth(let key):
            return "oauth:\(key)"
        }
    }

    init?(storageKey: String) {
        if storageKey == "ssh-library" {
            self = .legacySSHLibrary
            return
        }
        if storageKey.hasPrefix("ssh-key:"),
           let id = UUID(uuidString: String(storageKey.dropFirst("ssh-key:".count))) {
            self = .sshKey(id)
            return
        }
        if storageKey.hasPrefix("server:"),
           let id = UUID(uuidString: String(storageKey.dropFirst("server:".count))) {
            self = .server(id)
            return
        }
        if storageKey.hasPrefix("oauth:") {
            self = .oauth(String(storageKey.dropFirst("oauth:".count)))
            return
        }
        return nil
    }
}

nonisolated final class CredentialOfflineChangeStore: @unchecked Sendable {
    static let shared = CredentialOfflineChangeStore()

    private struct PersistedState: Codable, Equatable {
        var phase: CredentialReconciliationPhase
        var changes: [String: String]
        var changeDates: [String: Double]
        var requiresSyncDisableCommit: Bool?
    }

    private static let reconciliationStateKey = "vvterm.keychain.offlineReconciliation.v3"
    private static let stateKey = "vvterm.keychain.offlineChanges.v1"
    private static let trackingKey = "vvterm.keychain.offlineTracking.v1"
    private static let phaseKey = "vvterm.keychain.offlineReconciliationPhase.v2"
    private static let changeDatesKey = "vvterm.keychain.offlineChangeDates.v2"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isTrackingOfflineChanges: Bool {
        reconciliationPhase != nil
    }

    var reconciliationPhase: CredentialReconciliationPhase? {
        withLock {
            storedState()?.phase
        }
    }

    var requiresSyncDisableCommit: Bool {
        withLock {
            storedState()?.requiresSyncDisableCommit == true
        }
    }

    func beginOfflineSnapshotPreparation() throws {
        try withLock {
            try persist(
                PersistedState(
                    phase: .preparingOfflineSnapshot,
                    changes: [:],
                    changeDates: [:],
                    requiresSyncDisableCommit: nil
                )
            )
        }
    }

    func completeOfflineSnapshot(
        changes: [CredentialSyncUnit: CredentialOfflineChange]
    ) throws {
        try withLock {
            guard storedState()?.phase == .preparingOfflineSnapshot else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
            let values = Dictionary(
                uniqueKeysWithValues: changes.map { unit, change in
                    (unit.storageKey, change.rawValue)
                }
            )
            try persist(
                PersistedState(
                    phase: .remoteChanges,
                    changes: values,
                    changeDates: [:],
                    requiresSyncDisableCommit: true
                )
            )
        }
    }

    func finishSyncDisableCommit() throws {
        try withLock {
            guard var state = storedState(),
                  state.phase == .remoteChanges,
                  state.requiresSyncDisableCommit == true else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
            state.requiresSyncDisableCommit = nil
            try persist(state)
        }
    }

    func beginOfflineTracking(
        changes: [CredentialSyncUnit: CredentialOfflineChange]
    ) throws {
        try withLock {
            let values = Dictionary(
                uniqueKeysWithValues: changes.map { unit, change in
                    (unit.storageKey, change.rawValue)
                }
            )
            let changeDate = Date().timeIntervalSinceReferenceDate
            let dates = Dictionary(
                uniqueKeysWithValues: changes.compactMap { unit, change in
                    change == .unchanged ? nil : (unit.storageKey, changeDate)
                }
            )
            try persist(
                PersistedState(
                    phase: .remoteChanges,
                    changes: values,
                    changeDates: dates,
                    requiresSyncDisableCommit: nil
                )
            )
        }
    }

    func record(_ change: CredentialOfflineChange, for unit: CredentialSyncUnit) throws {
        try withLock {
            var state = storedState() ?? PersistedState(
                phase: .remoteChanges,
                changes: [:],
                changeDates: [:],
                requiresSyncDisableCommit: nil
            )
            guard state.phase == .remoteChanges,
                  state.requiresSyncDisableCommit != true else {
                throw CredentialSyncError.offlineReconciliationPending
            }
            state.phase = .remoteChanges
            state.changes[unit.storageKey] = change.rawValue
            state.changeDates[unit.storageKey] = Date().timeIntervalSinceReferenceDate
            try persist(state)
        }
    }

    func recordCloudRemovalRestoreIntent(for units: Set<CredentialSyncUnit>) throws {
        guard !units.isEmpty else { return }
        try withLock {
            guard var state = storedState(),
                  state.phase == .remoteChanges,
                  state.requiresSyncDisableCommit != true else {
                throw CredentialSyncError.offlineReconciliationPending
            }
            let changeDate = Date().timeIntervalSinceReferenceDate
            var didChange = false
            for unit in units {
                guard state.changes[unit.storageKey] == CredentialOfflineChange.unchanged.rawValue else {
                    continue
                }
                state.changes[unit.storageKey] = CredentialOfflineChange.updated.rawValue
                state.changeDates[unit.storageKey] = changeDate
                didChange = true
            }
            if didChange {
                try persist(state)
            }
        }
    }

    func change(for unit: CredentialSyncUnit) -> CredentialOfflineChange? {
        withLock {
            storedState()?.changes[unit.storageKey]
                .flatMap(CredentialOfflineChange.init(rawValue:))
        }
    }

    func changeDate(for unit: CredentialSyncUnit) -> Date? {
        withLock {
            storedState()?.changeDates[unit.storageKey]
                .map(Date.init(timeIntervalSinceReferenceDate:))
        }
    }

    func snapshot() -> [CredentialSyncUnit: CredentialOfflineChange] {
        withLock {
            Dictionary(
                uniqueKeysWithValues: (storedState()?.changes ?? [:]).compactMap { key, value in
                    guard let unit = CredentialSyncUnit(storageKey: key),
                          let change = CredentialOfflineChange(rawValue: value) else {
                        return nil
                    }
                    return (unit, change)
                }
            )
        }
    }

    func markRemoteChangesApplied() throws {
        try withLock {
            guard var state = storedState() else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
            state.phase = .localCleanup
            state.requiresSyncDisableCommit = nil
            try persist(state)
        }
    }

    func finishOnlineReconciliation() throws {
        try withLock {
            defaults.removeObject(forKey: Self.reconciliationStateKey)
            defaults.removeObject(forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.phaseKey)
            defaults.removeObject(forKey: Self.changeDatesKey)
            defaults.set(false, forKey: Self.trackingKey)
            guard defaults.object(forKey: Self.reconciliationStateKey) == nil,
                  defaults.object(forKey: Self.stateKey) == nil,
                  defaults.object(forKey: Self.phaseKey) == nil,
                  defaults.object(forKey: Self.changeDatesKey) == nil,
                  !defaults.bool(forKey: Self.trackingKey) else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
        }
    }

    private func persist(_ state: PersistedState) throws {
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: Self.reconciliationStateKey)
        guard defaults.data(forKey: Self.reconciliationStateKey) == data else {
            throw CredentialOfflineChangeStoreError.persistenceFailed
        }
    }

    private func storedState() -> PersistedState? {
        if let data = defaults.data(forKey: Self.reconciliationStateKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            return state
        }
        let legacyChanges = storedLegacyValues()
        let legacyPhase: CredentialReconciliationPhase?
        if let rawValue = defaults.string(forKey: Self.phaseKey) {
            legacyPhase = CredentialReconciliationPhase(rawValue: rawValue)
        } else {
            legacyPhase = defaults.bool(forKey: Self.trackingKey) ? .remoteChanges : nil
        }
        guard let legacyPhase else {
            return legacyChanges.isEmpty ? nil : PersistedState(
                phase: .remoteChanges,
                changes: legacyChanges,
                changeDates: storedLegacyChangeDates(),
                requiresSyncDisableCommit: nil
            )
        }
        return PersistedState(
            phase: legacyPhase,
            changes: legacyChanges,
            changeDates: storedLegacyChangeDates(),
            requiresSyncDisableCommit: nil
        )
    }

    fileprivate func loadOfflineWritePlan(service: String) throws -> CredentialOfflineWritePlan? {
        try withLock {
            guard let data = defaults.data(forKey: offlineWritePlanKey(service: service)) else {
                return nil
            }
            do {
                return try JSONDecoder().decode(CredentialOfflineWritePlan.self, from: data)
            } catch {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
        }
    }

    fileprivate func saveOfflineWritePlan(
        _ plan: CredentialOfflineWritePlan,
        service: String
    ) throws {
        try withLock {
            let data = try JSONEncoder().encode(plan)
            let key = offlineWritePlanKey(service: service)
            defaults.set(data, forKey: key)
            guard defaults.data(forKey: key) == data else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
        }
    }

    fileprivate func clearOfflineWritePlan(service: String) throws {
        try withLock {
            let key = offlineWritePlanKey(service: service)
            defaults.removeObject(forKey: key)
            guard defaults.object(forKey: key) == nil else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
        }
    }

    fileprivate func hasOfflineWritePlan(service: String) -> Bool {
        withLock {
            defaults.object(forKey: offlineWritePlanKey(service: service)) != nil
        }
    }

    private func offlineWritePlanKey(service: String) -> String {
        "vvterm.keychain.offlineWrite.\(service).v1"
    }

    private func storedLegacyValues() -> [String: String] {
        defaults.dictionary(forKey: Self.stateKey) as? [String: String] ?? [:]
    }

    private func storedLegacyChangeDates() -> [String: Double] {
        let values = defaults.dictionary(forKey: Self.changeDatesKey) ?? [:]
        return values.reduce(into: [:]) { result, element in
            if let number = element.value as? NSNumber {
                result[element.key] = number.doubleValue
            }
        }
    }

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

nonisolated struct CredentialOfflineWriteOperation: Sendable {
    let targetKey: String
    let value: Data?
}

nonisolated fileprivate struct CredentialOfflineWritePlan: Codable, Equatable, Sendable {
    struct Operation: Codable, Equatable, Sendable {
        let targetKey: String
        let stagingKey: String?
    }

    let unitStorageKey: String
    let operations: [Operation]
}

/// Stages secrets in device-only Keychain storage before making their change intent durable.
/// UserDefaults contains only target and staging key names, never credential values.
nonisolated final class CredentialOfflineWriteTransaction: @unchecked Sendable {
    private static let stagingPrefix = "vvterm.offline-write-stage."

    private let store: KeychainStore
    private let offlineChanges: CredentialOfflineChangeStore

    init(
        store: KeychainStore,
        offlineChanges: CredentialOfflineChangeStore
    ) {
        self.store = store
        self.offlineChanges = offlineChanges
    }

    var hasPendingWrite: Bool {
        offlineChanges.hasOfflineWritePlan(service: store.service)
    }

    func commitUpdate(
        for unit: CredentialSyncUnit,
        operations: [CredentialOfflineWriteOperation]
    ) throws {
        try resumePendingWrite()
        guard offlineChanges.reconciliationPhase != .preparingOfflineSnapshot,
              offlineChanges.reconciliationPhase != .localCleanup else {
            throw CredentialSyncError.offlineReconciliationPending
        }

        let transactionID = UUID().uuidString
        var stagedKeys: [String] = []
        let planOperations: [CredentialOfflineWritePlan.Operation]
        do {
            planOperations = try operations.enumerated().map { index, operation in
                guard let value = operation.value else {
                    return .init(targetKey: operation.targetKey, stagingKey: nil)
                }
                let stagingKey = "\(Self.stagingPrefix)\(transactionID).\(index)"
                try store.set(value, forKey: stagingKey, scope: .deviceOnly)
                guard try store.get(stagingKey, scope: .deviceOnly) == value else {
                    throw KeychainError.copyVerificationFailed
                }
                stagedKeys.append(stagingKey)
                return .init(targetKey: operation.targetKey, stagingKey: stagingKey)
            }
            try offlineChanges.saveOfflineWritePlan(
                CredentialOfflineWritePlan(
                    unitStorageKey: unit.storageKey,
                    operations: planOperations
                ),
                service: store.service
            )
        } catch {
            if !hasPendingWrite {
                for key in stagedKeys {
                    try? store.delete(key, scope: .deviceOnly)
                }
            }
            throw error
        }

        try resumePendingWrite()
    }

    func resumePendingWrite() throws {
        guard let plan = try offlineChanges.loadOfflineWritePlan(service: store.service) else {
            try removeOrphanedStagingValues()
            return
        }
        guard let unit = CredentialSyncUnit(storageKey: plan.unitStorageKey) else {
            throw CredentialOfflineChangeStoreError.persistenceFailed
        }

        try offlineChanges.record(.updated, for: unit)
        for operation in plan.operations {
            if let stagingKey = operation.stagingKey {
                guard let value = try store.get(stagingKey, scope: .deviceOnly) else {
                    throw KeychainError.itemNotFound
                }
                try store.set(value, forKey: operation.targetKey, scope: .deviceOnly)
                guard try store.get(operation.targetKey, scope: .deviceOnly) == value else {
                    throw KeychainError.copyVerificationFailed
                }
            } else {
                try store.delete(operation.targetKey, scope: .deviceOnly)
                guard try !store.contains(operation.targetKey, scope: .deviceOnly) else {
                    throw KeychainError.copyVerificationFailed
                }
            }
        }
        try offlineChanges.clearOfflineWritePlan(service: store.service)
        for operation in plan.operations {
            if let stagingKey = operation.stagingKey {
                try? store.delete(stagingKey, scope: .deviceOnly)
            }
        }
    }

    private func removeOrphanedStagingValues() throws {
        for key in try store.keys(in: .deviceOnly) where key.hasPrefix(Self.stagingPrefix) {
            try store.delete(key, scope: .deviceOnly)
        }
    }
}

nonisolated enum CredentialOfflineChangeStoreError: Error, Equatable, Sendable {
    case persistenceFailed
}

nonisolated enum CredentialSyncError: LocalizedError, Equatable, Sendable {
    case offlineReconciliationPending
    case syncMustBeDisabled

    var errorDescription: String? {
        switch self {
        case .offlineReconciliationPending:
            "Credential reconciliation must finish before credentials can change."
        case .syncMustBeDisabled:
            "Turn off iCloud Sync before removing credentials from iCloud Keychain."
        }
    }
}
