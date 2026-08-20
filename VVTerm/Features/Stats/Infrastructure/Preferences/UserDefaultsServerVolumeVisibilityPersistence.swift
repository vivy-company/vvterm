import Foundation

@MainActor
final class UserDefaultsServerVolumeVisibilityPersistence:
    ServerVolumeVisibilityPreferencesPersisting {
    static let storageKey = "stats.serverVolumeVisibility.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadPreferences() -> ServerVolumeVisibilityPreferences {
        guard let data = defaults.data(forKey: Self.storageKey),
              let preferences = try? JSONDecoder().decode(
                  ServerVolumeVisibilityPreferences.self,
                  from: data
              ) else {
            return ServerVolumeVisibilityPreferences()
        }
        return preferences
    }

    func savePreferences(_ preferences: ServerVolumeVisibilityPreferences) {
        guard !containsFutureSchema else { return }
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private var containsFutureSchema: Bool {
        guard let data = defaults.data(forKey: Self.storageKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? NSNumber else {
            return false
        }
        return schemaVersion.intValue > ServerVolumeVisibilityPreferences.currentSchemaVersion
    }
}

@MainActor
extension ServerVolumeVisibilityStore {
    static var live: ServerVolumeVisibilityStore {
        ServerVolumeVisibilityStore(
            persistence: UserDefaultsServerVolumeVisibilityPersistence(defaults: .standard)
        )
    }
}
