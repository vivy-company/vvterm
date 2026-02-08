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

        let connectionModeRaw = record["connectionMode"] as? String
        let connectionMode = connectionModeRaw.flatMap(SSHConnectionMode.init(rawValue:)) ?? .standard
        let cloudflareAccessModeRaw = record["cloudflareAccessMode"] as? String
        let cloudflareAccessMode = cloudflareAccessModeRaw.flatMap(CloudflareAccessMode.init(rawValue:))
        let cloudflareTeamDomainOverride = record["cloudflareTeamDomainOverride"] as? String
        let cloudflareAppDomainOverride = record["cloudflareAppDomainOverride"] as? String

        logger.info("Successfully decoded server: \(name) (id: \(id), workspaceId: \(workspaceId))")

        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.connectionMode = connectionMode
        self.authMethod = authMethod
        self.cloudflareAccessMode = cloudflareAccessMode
        self.cloudflareTeamDomainOverride = cloudflareTeamDomainOverride
        self.cloudflareAppDomainOverride = cloudflareAppDomainOverride
        self.tags = record["tags"] as? [String] ?? []
        self.notes = record["notes"] as? String
        self.lastConnected = record["lastConnected"] as? Date
        self.isFavorite = record["isFavorite"] as? Bool ?? false
        self.tmuxEnabledOverride = record["tmuxEnabledOverride"] as? Bool
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.updatedAt = record["updatedAt"] as? Date ?? Date()

        // Decode environment
        if let envData = record["environment"] as? Data,
           let environment = try? JSONDecoder().decode(ServerEnvironment.self, from: envData) {
            self.environment = environment
        } else {
            self.environment = .production
        }
    }

    func toRecord(in zoneID: CKRecordZone.ID? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID ?? CKRecordZone.default().zoneID)
        let record = CKRecord(recordType: "Server", recordID: recordID)

        record["workspaceId"] = workspaceId.uuidString
        record["name"] = name
        record["host"] = host
        record["port"] = port
        record["username"] = username
        if connectionMode != .standard {
            record["connectionMode"] = connectionMode.rawValue
        } else {
            record["connectionMode"] = nil
        }
        record["authMethod"] = authMethod.rawValue
        if let cloudflareAccessMode {
            record["cloudflareAccessMode"] = cloudflareAccessMode.rawValue
        } else {
            record["cloudflareAccessMode"] = nil
        }
        if let cloudflareTeamDomainOverride, !cloudflareTeamDomainOverride.isEmpty {
            record["cloudflareTeamDomainOverride"] = cloudflareTeamDomainOverride
        } else {
            record["cloudflareTeamDomainOverride"] = nil
        }
        if let cloudflareAppDomainOverride, !cloudflareAppDomainOverride.isEmpty {
            record["cloudflareAppDomainOverride"] = cloudflareAppDomainOverride
        } else {
            record["cloudflareAppDomainOverride"] = nil
        }
        // CloudKit rejects empty arrays for new fields - only set if non-empty
        if !tags.isEmpty {
            record["tags"] = tags
        }
        record["notes"] = notes
        record["lastConnected"] = lastConnected
        record["isFavorite"] = isFavorite
        record["tmuxEnabledOverride"] = tmuxEnabledOverride
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()

        if let envData = try? JSONEncoder().encode(environment) {
            record["environment"] = envData
        }

        return record
    }
}
