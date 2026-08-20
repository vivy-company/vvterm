import Foundation

enum SyncSettings {
    nonisolated static let enabledKey = CloudKitSyncConstants.syncEnabledKey

    nonisolated static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    nonisolated static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    nonisolated static func persistEnabled(
        _ enabled: Bool,
        in defaults: UserDefaults = .standard
    ) throws {
        defaults.set(enabled, forKey: enabledKey)
        guard defaults.object(forKey: enabledKey) as? Bool == enabled else {
            throw SyncSettingsPersistenceError.persistenceFailed
        }
    }
}

nonisolated enum SyncSettingsPersistenceError: Error, Sendable {
    case persistenceFailed
}
