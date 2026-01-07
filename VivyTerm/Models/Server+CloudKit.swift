import Foundation
import CloudKit
import os.log

// MARK: - CloudKit Serialization

extension Server {
    init?(from record: CKRecord) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Server.CloudKit")

        guard let idString = record.recordID.recordName as String?,
              let id = UUID(uuidString: idString) else {
            logger.error("Failed to decode server: invalid recordID '\(record.recordID.recordName)'")
            return nil
        }

        guard let workspaceIdString = record["workspaceId"] as? String,
              let workspaceId = UUID(uuidString: workspaceIdString) else {
            logger.error("Server \(id): missing/invalid workspaceId. Raw value: \(String(describing: record["workspaceId"]))")
            return nil
        }

        guard let name = record["name"] as? String else {
            logger.error("Server \(id): missing name")
            return nil
        }

        guard let host = record["host"] as? String else {
            logger.error("Server \(id): missing host")
            return nil
        }

        guard let port = record["port"] as? Int else {
            logger.error("Server \(id): missing/invalid port. Raw value: \(String(describing: record["port"]))")
            return nil
        }

        guard let username = record["username"] as? String else {
            logger.error("Server \(id): missing username")
            return nil
        }

        guard let authMethodRaw = record["authMethod"] as? String,
              let authMethod = AuthMethod(rawValue: authMethodRaw) else {
            logger.error("Server \(id): invalid authMethod. Raw value: \(String(describing: record["authMethod"]))")
            return nil
        }

        logger.info("Successfully decoded server: \(name) (id: \(id), workspaceId: \(workspaceId))")

        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.tags = record["tags"] as? [String] ?? []
        self.notes = record["notes"] as? String
        self.lastConnected = record["lastConnected"] as? Date
        self.isFavorite = record["isFavorite"] as? Bool ?? false
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.updatedAt = record["updatedAt"] as? Date ?? Date()
        self.keychainCredentialId = record["keychainCredentialId"] as? String ?? id.uuidString

        // Decode environment
        if let envData = record["environment"] as? Data,
           let environment = try? JSONDecoder().decode(ServerEnvironment.self, from: envData) {
            self.environment = environment
        } else {
            self.environment = .production
        }
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let record = CKRecord(recordType: "Server", recordID: recordID)

        record["workspaceId"] = workspaceId.uuidString
        record["name"] = name
        record["host"] = host
        record["port"] = port
        record["username"] = username
        record["authMethod"] = authMethod.rawValue
        // CloudKit rejects empty arrays for new fields - only set if non-empty
        if !tags.isEmpty {
            record["tags"] = tags
        }
        record["notes"] = notes
        record["lastConnected"] = lastConnected
        record["isFavorite"] = isFavorite
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["keychainCredentialId"] = keychainCredentialId

        if let envData = try? JSONEncoder().encode(environment) {
            record["environment"] = envData
        }

        return record
    }
}
