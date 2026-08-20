import Foundation

nonisolated enum CloudKitSyncConstants {
    static let appPrefix = "com.vivy.vvterm"
    static let cloudKitContainerIdentifier = "iCloud.app.vivy.VivyTerm"
    static let recordZoneName = "VVTermZone"
    static let databaseSubscriptionID = "database-changes"

    static let syncEnabledKey = "iCloudSyncEnabled"
    static let pendingCloudKitSyncQueueStorageKey = "\(appPrefix).pendingCloudKitSyncQueue"

    static func changeTokenKey(for zoneName: String = recordZoneName) -> String {
        "\(appPrefix).cloudkit.\(zoneName).token"
    }

    static func zoneReadyKey(for zoneName: String = recordZoneName) -> String {
        "\(appPrefix).cloudkit.\(zoneName).ready"
    }
}
