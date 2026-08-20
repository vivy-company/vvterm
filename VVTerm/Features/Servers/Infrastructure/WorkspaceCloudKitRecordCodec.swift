import CloudKit
import Foundation

nonisolated enum WorkspaceCloudKitRecordCodec {
    static let recordType = "Workspace"
    static let recordKeys = [
        "name", "colorHex", "icon", "order", "createdAt", "updatedAt",
        "lastSelectedEnvironmentId", "lastSelectedServerId", "environments"
    ]

    static func workspace(from record: CKRecord, now: Date) -> Workspace? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let name = record["name"] as? String,
              let colorHex = record["colorHex"] as? String else {
            return nil
        }

        let environments: [ServerEnvironment]
        if let data = record["environments"] as? Data,
           let decoded = try? JSONDecoder().decode([ServerEnvironment].self, from: data) {
            environments = decoded
        } else {
            environments = ServerEnvironment.builtInEnvironments
        }

        return Workspace(
            id: id,
            name: name,
            colorHex: colorHex,
            icon: record["icon"] as? String,
            order: record["order"] as? Int ?? 0,
            environments: environments,
            lastSelectedEnvironmentId: (record["lastSelectedEnvironmentId"] as? String)
                .flatMap(UUID.init(uuidString:)),
            lastSelectedServerId: (record["lastSelectedServerId"] as? String)
                .flatMap(UUID.init(uuidString:)),
            createdAt: record["createdAt"] as? Date ?? now,
            updatedAt: record["updatedAt"] as? Date ?? now
        )
    }

    static func record(
        for workspace: Workspace,
        in zoneID: CKRecordZone.ID,
        now: Date
    ) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: workspace.id.uuidString,
            zoneID: zoneID
        )
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["name"] = workspace.name
        record["colorHex"] = workspace.colorHex
        record["icon"] = workspace.icon
        record["order"] = workspace.order
        record["createdAt"] = workspace.createdAt
        record["updatedAt"] = now
        record["lastSelectedEnvironmentId"] = workspace.lastSelectedEnvironmentId?.uuidString
        record["lastSelectedServerId"] = workspace.lastSelectedServerId?.uuidString
        if let environments = try? JSONEncoder().encode(workspace.environments) {
            record["environments"] = environments
        }
        return record
    }
}
