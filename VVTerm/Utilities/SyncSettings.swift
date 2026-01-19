import Foundation

enum SyncSettings {
    static let enabledKey = "iCloudSyncEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
