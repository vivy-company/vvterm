import Foundation

@MainActor
protocol AppLockPreferences: AnyObject {
    var fullAppLockEnabled: Bool? { get set }
    var lockOnBackground: Bool? { get set }
    var authGraceSeconds: Int? { get set }
}

@MainActor
struct AppLockManagerDependencies {
    let preferences: any AppLockPreferences
    let authService: any BiometricAuthServing
    let now: () -> Date
    let makeID: () -> UUID
}
