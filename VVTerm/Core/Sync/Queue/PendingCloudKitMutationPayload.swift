import Foundation

nonisolated enum PendingCloudKitMutationOperation: String, Codable, Equatable, Sendable {
    case upsert
    case delete
}

nonisolated struct PendingCloudKitPayloadEnvelope: Codable, Equatable, Sendable {
    let entityType: String
    let entityKey: String
    let operation: PendingCloudKitMutationOperation
    let drainPriority: Int
    let encodedValue: Data

    init<Value: Encodable>(
        entityType: String,
        entityKey: String,
        operation: PendingCloudKitMutationOperation,
        drainPriority: Int,
        value: Value
    ) throws {
        self.entityType = entityType
        self.entityKey = entityKey
        self.operation = operation
        self.drainPriority = drainPriority
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encodedValue = try encoder.encode(value)
    }

    var coalescingKey: String {
        "\(entityType):\(entityKey)"
    }

    var isDelete: Bool {
        operation == .delete
    }

    var description: String {
        "\(entityType) \(operation.rawValue) \(entityKey)"
    }

    func decode<Value: Decodable>(
        _ type: Value.Type,
        entityType expectedEntityType: String,
        operation expectedOperation: PendingCloudKitMutationOperation
    ) throws -> Value? {
        guard entityType == expectedEntityType,
              operation == expectedOperation else {
            return nil
        }
        return try JSONDecoder().decode(type, from: encodedValue)
    }

    func validate(entityKey expectedEntityKey: String, drainPriority expectedPriority: Int) throws {
        guard entityKey == expectedEntityKey,
              drainPriority == expectedPriority else {
            throw PendingCloudKitPayloadEnvelopeError.invalidRoutingMetadata
        }
    }
}

nonisolated enum PendingCloudKitPayloadEnvelopeError: Error, Equatable {
    case invalidRoutingMetadata
}
