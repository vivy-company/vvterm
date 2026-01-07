import Foundation
import CloudKit

// MARK: - CloudKit Serialization

extension Workspace {
    init?(from record: CKRecord) {
        guard
            let idString = record.recordID.recordName as String?,
            let id = UUID(uuidString: idString),
            let name = record["name"] as? String,
            let colorHex = record["colorHex"] as? String
        else {
            return nil
        }

        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = record["icon"] as? String
        self.order = record["order"] as? Int ?? 0
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.updatedAt = record["updatedAt"] as? Date ?? Date()

        if let lastEnvIdString = record["lastSelectedEnvironmentId"] as? String {
            self.lastSelectedEnvironmentId = UUID(uuidString: lastEnvIdString)
        } else {
            self.lastSelectedEnvironmentId = nil
        }

        if let lastServerIdString = record["lastSelectedServerId"] as? String {
            self.lastSelectedServerId = UUID(uuidString: lastServerIdString)
        } else {
            self.lastSelectedServerId = nil
        }

        // Decode environments
        if let envData = record["environments"] as? Data,
           let environments = try? JSONDecoder().decode([ServerEnvironment].self, from: envData) {
            self.environments = environments
        } else {
            self.environments = ServerEnvironment.builtInEnvironments
        }
    }

    func toRecord() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let record = CKRecord(recordType: "Workspace", recordID: recordID)

        record["name"] = name
        record["colorHex"] = colorHex
        record["icon"] = icon
        record["order"] = order
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["lastSelectedEnvironmentId"] = lastSelectedEnvironmentId?.uuidString
        record["lastSelectedServerId"] = lastSelectedServerId?.uuidString

        if let envData = try? JSONEncoder().encode(environments) {
            record["environments"] = envData
        }

        return record
    }
}
