import Foundation
import os.log

@MainActor
final class UserDefaultsStatsPreferencesStore: StatsPreferencesPersisting {
    static let storageKey = "statsPreferencesV1"

    private let defaults: UserDefaults
    private let key: String
    private let logger = Logger(
        subsystem: "app.vivy.vvterm",
        category: "StatsPreferencesStore"
    )

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func loadPreferences(defaultWriterID writerID: String) -> StatsPreferences {
        guard let data = defaults.data(forKey: key) else {
            return repairWithDefaultPreferences(writerID: writerID)
        }

        do {
            var decoded = try JSONDecoder().decode(StatsPreferences.self, from: data)
            if decoded.lastWriterDeviceId.isEmpty {
                decoded.lastWriterDeviceId = writerID
            }
            let normalized = decoded.normalized()
            if normalized != decoded {
                savePreferences(normalized)
            }
            return normalized
        } catch {
            logger.error("Failed to decode stats preferences: \(error.localizedDescription)")
            return repairWithDefaultPreferences(writerID: writerID)
        }
    }

    func savePreferences(_ preferences: StatsPreferences) {
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: key)
        } catch {
            logger.error("Failed to encode stats preferences: \(error.localizedDescription)")
        }
    }

    private func repairWithDefaultPreferences(writerID: String) -> StatsPreferences {
        let preferences = StatsPreferences
            .defaultValue(lastWriterDeviceId: writerID)
            .normalized()
        savePreferences(preferences)
        return preferences
    }
}
