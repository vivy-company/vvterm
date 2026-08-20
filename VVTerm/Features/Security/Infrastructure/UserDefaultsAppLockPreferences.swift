import Foundation

@MainActor
final class UserDefaultsAppLockPreferences: AppLockPreferences {
    private enum Key {
        static let fullAppLockEnabled = "security.fullAppLockEnabled"
        static let lockOnBackground = "security.lockOnBackground"
        static let authGraceSeconds = "security.authGraceSeconds"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var fullAppLockEnabled: Bool? {
        get { defaults.object(forKey: Key.fullAppLockEnabled) as? Bool }
        set { set(newValue, forKey: Key.fullAppLockEnabled) }
    }

    var lockOnBackground: Bool? {
        get { defaults.object(forKey: Key.lockOnBackground) as? Bool }
        set { set(newValue, forKey: Key.lockOnBackground) }
    }

    var authGraceSeconds: Int? {
        get { defaults.object(forKey: Key.authGraceSeconds) as? Int }
        set { set(newValue, forKey: Key.authGraceSeconds) }
    }

    private func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
