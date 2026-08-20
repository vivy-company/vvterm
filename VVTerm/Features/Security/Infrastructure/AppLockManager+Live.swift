import Foundation

extension AppLockManager {
    convenience init(
        defaults: UserDefaults = .standard,
        authService: (any BiometricAuthServing)? = nil,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        let resolvedAuthService = authService ?? BiometricAuthService.shared
        self.init(
            dependencies: AppLockManagerDependencies(
                preferences: UserDefaultsAppLockPreferences(defaults: defaults),
                authService: resolvedAuthService,
                now: now,
                makeID: makeID
            )
        )
    }
}
