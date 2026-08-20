import Foundation
import LocalAuthentication

@MainActor
final class BiometricAuthService: BiometricAuthServing {
    static let shared = BiometricAuthService()

    private init() {}

    func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .available(Self.mapBiometryType(context.biometryType))
        }

        return .unavailable(Self.unavailability(for: error))
    }

    func authenticate(
        reason: BiometricAuthenticationReason,
        allowPasscodeFallback: Bool = true
    ) async throws {
        let context = LAContext()
        let policy: LAPolicy = allowPasscodeFallback
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics

        do {
            _ = try await context.evaluatePolicy(
                policy,
                localizedReason: Self.localizedReason(for: reason)
            )
        } catch {
            throw Self.authenticationFailure(for: error)
        }
    }

    static func localizedReason(for reason: BiometricAuthenticationReason) -> String {
        switch reason {
        case .enableAppLock(let biometry):
            return String(
                format: String(localized: "Enable %@ for VVTerm"),
                localizedName(for: biometry)
            )
        case .disableAppLock:
            return String(localized: "Authenticate to disable the VVTerm app lock")
        case .unlockApp(let biometry):
            return String(
                format: String(localized: "Unlock VVTerm with %@"),
                localizedName(for: biometry)
            )
        case .unlockServer(let name):
            return String(format: String(localized: "Unlock server %@"), name)
        case .protectedServerAction(let action, let serverName):
            return String(
                format: String(localized: "Authenticate to %@ server %@"),
                localizedActionName(for: action),
                serverName
            )
        }
    }

    private static func mapBiometryType(_ type: LABiometryType) -> BiometryKind {
        switch type {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        default:
            return .none
        }
    }

    private static func localizedName(for biometry: BiometryKind) -> String {
        switch biometry {
        case .none:
            return String(localized: "Biometric Authentication")
        case .touchID:
            return String(localized: "Touch ID")
        case .faceID:
            return String(localized: "Face ID")
        }
    }

    private static func localizedActionName(
        for action: AppLockAuthenticationState.ProtectedServerAction
    ) -> String {
        switch action {
        case .edit:
            return String(localized: "edit")
        case .testConnection:
            return String(localized: "test")
        case .save:
            return String(localized: "save")
        case .delete:
            return String(localized: "delete")
        }
    }

    static func unavailability(for error: NSError?) -> BiometricUnavailability {
        guard let error else {
            return .notAvailable
        }

        if error.domain == LAError.errorDomain,
           let code = LAError.Code(rawValue: error.code) {
            switch code {
            case .biometryNotEnrolled:
                return .notEnrolled
            case .biometryNotAvailable:
                return .notAvailable
            case .biometryLockout:
                return .locked
            case .passcodeNotSet:
                return .passcodeNotSet
            default:
                break
            }
        }

        return .system(message: error.localizedDescription)
    }

    static func authenticationFailure(for error: Error) -> BiometricAuthenticationFailure {
        if error is CancellationError {
            return .cancelled
        }

        let nsError = error as NSError

        guard nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code) else {
            return .system(message: nsError.localizedDescription)
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .cancelled
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryLockout:
            return .locked
        case .passcodeNotSet:
            return .passcodeNotSet
        case .authenticationFailed:
            return .authenticationFailed
        default:
            return .system(message: nsError.localizedDescription)
        }
    }
}
