import CloudKit
import Combine
import Foundation

nonisolated struct PendingCloudKitMutation: Codable, Equatable, Identifiable, Sendable {
    static let maximumRetryCount = 64

    let id: UUID
    let payload: PendingCloudKitMutationPayload
    let createdAt: Date
    private(set) var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var lastErrorDescription: String?

    private static let baseRetryDelay: TimeInterval = 30
    private static let maximumRetryDelay: TimeInterval = 3_600
    private static let maximumRetryExponent = 7

    private enum CodingKeys: String, CodingKey {
        case id
        case payload
        case createdAt
        case retryCount
        case nextRetryAt
        case lastErrorCode
        case lastErrorDescription
    }

    init(
        id: UUID = UUID(),
        payload: PendingCloudKitMutationPayload,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastErrorCode: String? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = Self.boundedRetryCount(retryCount)
        self.nextRetryAt = nextRetryAt
        self.lastErrorCode = lastErrorCode
        self.lastErrorDescription = lastErrorDescription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        payload = try container.decode(PendingCloudKitMutationPayload.self, forKey: .payload)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        retryCount = Self.boundedRetryCount(try container.decode(Int.self, forKey: .retryCount))
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorDescription = try container.decodeIfPresent(String.self, forKey: .lastErrorDescription)
    }

    var entityKey: String { payload.entityKey }
    var drainPriority: Int { payload.drainPriority }
    var entityDescription: String { payload.description }

    static func drainsBefore(_ lhs: PendingCloudKitMutation, _ rhs: PendingCloudKitMutation) -> Bool {
        if lhs.drainPriority != rhs.drainPriority {
            return lhs.drainPriority < rhs.drainPriority
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    func canAttempt(at date: Date) -> Bool {
        guard let nextRetryAt else { return true }
        return nextRetryAt <= date
    }

    func withFailure(error: Error, at date: Date = Date()) -> PendingCloudKitMutation {
        var copy = self
        copy.retryCount = Self.boundedRetryCount(copy.retryCount)
        if copy.retryCount < Self.maximumRetryCount {
            copy.retryCount += 1
        }
        copy.lastErrorDescription = error.localizedDescription
        copy.lastErrorCode = Self.errorCodeString(for: error)

        let exponent = min(max(copy.retryCount - 1, 0), Self.maximumRetryExponent)
        let delay = min(
            Self.baseRetryDelay * pow(2, Double(exponent)),
            Self.maximumRetryDelay
        )
        copy.nextRetryAt = date.addingTimeInterval(delay)
        return copy
    }

    static func errorCodeString(for error: Error) -> String? {
        if let ckError = error as? CKError {
            return String(describing: ckError.code)
        }
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func boundedRetryCount(_ retryCount: Int) -> Int {
        min(max(retryCount, 0), maximumRetryCount)
    }
}

nonisolated enum PendingCloudKitMutationQuarantineReason: String, Codable, Equatable, Error, Sendable {
    case unreadableLegacyRecord
    case missingOrConflictingPayload
    case mismatchedEntityKey
    case unsupportedOperation
}

nonisolated struct PendingCloudKitMutationQuarantine: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let legacyMutationID: UUID?
    let reason: PendingCloudKitMutationQuarantineReason
    let encodedLegacyRecord: Data
    let quarantinedAt: Date
}

nonisolated enum PendingCloudKitQueueHealth: Equatable, Sendable {
    case ready
    case migrationBlocked
}

nonisolated struct PendingCloudKitQueueSummary: Equatable, Sendable {
    let pendingOperationCount: Int
    let hasPendingFailure: Bool
    let quarantinedOperationCount: Int
    let health: PendingCloudKitQueueHealth

    static let empty = PendingCloudKitQueueSummary(
        pendingOperationCount: 0,
        hasPendingFailure: false,
        quarantinedOperationCount: 0,
        health: .ready
    )
}

nonisolated final class PendingCloudKitSyncQueue {
    private enum State {
        case ready
        case migrationFailed(String)
    }

    private static let quarantineStorageKeySuffix = ".quarantine.v1"

    private let storageKey: String
    private let quarantineStorageKey: String
    private let defaults: UserDefaults
    private let legacyMigrator: (any PendingCloudKitLegacyMutationMigrating)?
    private let summarySubject: CurrentValueSubject<PendingCloudKitQueueSummary, Never>
    private var items: [PendingCloudKitMutation]
    private var quarantinedItems: [PendingCloudKitMutationQuarantine]
    private var state: State

    init(
        storageKey: String = CloudKitSyncConstants.pendingCloudKitSyncQueueStorageKey,
        defaults: UserDefaults = .standard,
        legacyMigrator: (any PendingCloudKitLegacyMutationMigrating)? = nil
    ) {
        self.storageKey = storageKey
        self.quarantineStorageKey = storageKey + Self.quarantineStorageKeySuffix
        self.defaults = defaults
        self.legacyMigrator = legacyMigrator
        self.summarySubject = CurrentValueSubject(.empty)
        self.items = []
        self.quarantinedItems = []
        self.state = .ready
        loadQuarantine()
        load()
        publishSummary()
    }

    var summary: PendingCloudKitQueueSummary {
        PendingCloudKitQueueSummary(
            pendingOperationCount: items.count,
            hasPendingFailure: items.contains {
                $0.lastErrorCode != nil || $0.lastErrorDescription != nil
            },
            quarantinedOperationCount: quarantinedItems.count,
            health: queueHealth
        )
    }

    var summaryUpdates: AnyPublisher<PendingCloudKitQueueSummary, Never> {
        summarySubject.eraseToAnyPublisher()
    }

    func snapshot() -> [PendingCloudKitMutation] {
        items
    }

    func readySnapshot() throws -> [PendingCloudKitMutation] {
        try requireReady()
        return items
    }

    func quarantineSnapshot() -> [PendingCloudKitMutationQuarantine] {
        quarantinedItems
    }

    func enqueue(_ mutation: PendingCloudKitMutation) throws {
        try enqueueAtomically([mutation])
    }

    func enqueueAtomically(_ mutations: [PendingCloudKitMutation]) throws {
        try requireReady()
        var updatedItems = items
        for mutation in mutations {
            updatedItems.removeAll {
                $0.payload.coalescingKey == mutation.payload.coalescingKey
            }
            updatedItems.append(mutation)
        }

        try persistItems(updatedItems)
    }

    func remove(_ mutationID: UUID) throws {
        try requireReady()
        var updatedItems = items
        updatedItems.removeAll { $0.id == mutationID }
        try persistItems(updatedItems)
    }

    func removeAll(where shouldRemove: (PendingCloudKitMutation) -> Bool) throws {
        try requireReady()
        var updatedItems = items
        updatedItems.removeAll(where: shouldRemove)
        try persistItems(updatedItems)
    }

    func canAttempt(_ mutation: PendingCloudKitMutation, at date: Date) -> Bool {
        mutation.canAttempt(at: date)
    }

    func recordFailure(
        for mutation: PendingCloudKitMutation,
        error: Error,
        at date: Date
    ) throws {
        try requireReady()
        guard let index = items.firstIndex(where: { $0.id == mutation.id }) else {
            return
        }

        var updatedItems = items
        updatedItems[index] = updatedItems[index].withFailure(error: error, at: date)
        try persistItems(updatedItems)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            return
        }

        if let decoded = try? JSONDecoder().decode([PendingCloudKitMutation].self, from: data) {
            items = decoded
            state = .ready
            return
        }

        migrateLegacyQueue(from: data)
    }

    private func migrateLegacyQueue(from data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let records = object as? [Any] else {
            var updatedQuarantinedItems = quarantinedItems
            quarantine(
                data,
                legacyMutationID: nil,
                reason: .unreadableLegacyRecord,
                in: &updatedQuarantinedItems
            )
            persistMigrationOrBlock(
                items: [],
                quarantinedItems: updatedQuarantinedItems
            )
            return
        }

        var migratedItems: [PendingCloudKitMutation] = []
        var updatedQuarantinedItems = quarantinedItems
        for record in records {
            guard let recordData = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.fragmentsAllowed]
            ) else {
                quarantine(
                    Data(),
                    legacyMutationID: nil,
                    reason: .unreadableLegacyRecord,
                    in: &updatedQuarantinedItems
                )
                continue
            }

            guard let migration = legacyMigrator?.migrate(recordData: recordData) else {
                quarantine(
                    recordData,
                    legacyMutationID: nil,
                    reason: .unreadableLegacyRecord,
                    in: &updatedQuarantinedItems
                )
                continue
            }

            switch migration {
            case .success(let mutation):
                migratedItems.removeAll {
                    $0.payload.coalescingKey == mutation.payload.coalescingKey
                }
                migratedItems.append(mutation)
            case .failure(let reason):
                quarantine(
                    recordData,
                    legacyMutationID: Self.legacyMutationID(in: recordData),
                    reason: reason,
                    in: &updatedQuarantinedItems
                )
            }
        }

        persistMigrationOrBlock(
            items: migratedItems,
            quarantinedItems: updatedQuarantinedItems
        )
    }

    func retryMigration() throws {
        guard case .migrationFailed = state else { return }
        state = .ready
        load()
        try requireReady()
        publishSummary()
    }

    private func persistMigrationOrBlock(
        items: [PendingCloudKitMutation],
        quarantinedItems: [PendingCloudKitMutationQuarantine]
    ) {
        do {
            try persistMigratedState(
                items: items,
                quarantinedItems: quarantinedItems
            )
            state = .ready
        } catch {
            state = .migrationFailed(error.localizedDescription)
        }
        publishSummary()
    }

    private func requireReady() throws {
        switch state {
        case .ready:
            return
        case .migrationFailed(let reason):
            throw PendingCloudKitSyncQueueError.migrationFailed(reason)
        }
    }

    private func quarantine(
        _ data: Data,
        legacyMutationID: UUID?,
        reason: PendingCloudKitMutationQuarantineReason,
        in quarantinedItems: inout [PendingCloudKitMutationQuarantine]
    ) {
        guard !quarantinedItems.contains(where: {
            $0.legacyMutationID == legacyMutationID &&
            $0.reason == reason &&
            $0.encodedLegacyRecord == data
        }) else {
            return
        }

        quarantinedItems.append(
            PendingCloudKitMutationQuarantine(
                id: UUID(),
                legacyMutationID: legacyMutationID,
                reason: reason,
                encodedLegacyRecord: data,
                quarantinedAt: Date()
            )
        )
    }

    private func loadQuarantine() {
        guard let data = defaults.data(forKey: quarantineStorageKey),
              let decoded = try? JSONDecoder().decode(
                [PendingCloudKitMutationQuarantine].self,
                from: data
              ) else {
            return
        }
        quarantinedItems = decoded
    }

    private func persistItems(_ updatedItems: [PendingCloudKitMutation]) throws {
        let data = try JSONEncoder().encode(updatedItems)
        try writeAndVerify(data, forKey: storageKey)
        items = updatedItems
        publishSummary()
    }

    private func persistMigratedState(
        items updatedItems: [PendingCloudKitMutation],
        quarantinedItems updatedQuarantinedItems: [PendingCloudKitMutationQuarantine]
    ) throws {
        let itemsData = try JSONEncoder().encode(updatedItems)
        let quarantineData = try JSONEncoder().encode(updatedQuarantinedItems)
        let previousItemsData = defaults.data(forKey: storageKey)
        let previousQuarantineData = defaults.data(forKey: quarantineStorageKey)

        do {
            // Preserve invalid legacy records before replacing the legacy queue.
            try writeAndVerify(quarantineData, forKey: quarantineStorageKey)
            try writeAndVerify(itemsData, forKey: storageKey)
        } catch {
            restore(previousItemsData, forKey: storageKey)
            restore(previousQuarantineData, forKey: quarantineStorageKey)
            throw error
        }

        items = updatedItems
        quarantinedItems = updatedQuarantinedItems
        publishSummary()
    }

    private var queueHealth: PendingCloudKitQueueHealth {
        switch state {
        case .ready:
            .ready
        case .migrationFailed:
            .migrationBlocked
        }
    }

    private func publishSummary() {
        summarySubject.send(summary)
    }

    private func writeAndVerify(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw PendingCloudKitSyncQueueError.persistenceFailed
        }
    }

    private func restore(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func legacyMutationID(in data: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              let rawID = record["id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}

nonisolated enum PendingCloudKitSyncQueueError: LocalizedError, Sendable {
    case persistenceFailed
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .persistenceFailed:
            return "The pending CloudKit mutation queue could not be saved."
        case .migrationFailed(let reason):
            return "The pending CloudKit mutation queue migration is blocked: \(reason)"
        }
    }
}
