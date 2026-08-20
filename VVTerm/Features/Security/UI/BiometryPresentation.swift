import Foundation

extension BiometryKind {
    var displayName: String {
        switch self {
        case .none:
            return String(localized: "Biometric Authentication")
        case .touchID:
            return String(localized: "Touch ID")
        case .faceID:
            return String(localized: "Face ID")
        }
    }
}

extension BiometricUnavailability {
    var message: String {
        switch self {
        case .notEnrolled:
            return String(localized: "Biometric authentication is not set up on this device.")
        case .notAvailable:
            return String(localized: "Biometric authentication is unavailable on this device.")
        case .locked:
            return String(localized: "Biometric authentication is locked. Unlock the device to try again.")
        case .passcodeNotSet:
            return String(localized: "Set a device passcode before using biometric authentication.")
        case .system(let message):
            return message
        }
    }
}

extension BiometricAuthenticationFailure {
    var message: String? {
        switch self {
        case .cancelled:
            return nil
        case .notEnrolled:
            return String(localized: "Biometric authentication is not set up on this device.")
        case .notAvailable:
            return String(localized: "Biometric authentication is unavailable on this device.")
        case .locked:
            return String(localized: "Biometric authentication is locked. Unlock the device and try again.")
        case .passcodeNotSet:
            return String(localized: "Set a device passcode before using biometric authentication.")
        case .authenticationFailed:
            return String(localized: "Authentication failed.")
        case .system(let message):
            return message
        }
    }
}

extension AppLockFailure {
    var message: String? {
        switch self {
        case .biometryUnavailable(let reason):
            return reason.message
        case .authentication(let failure):
            return failure.message
        }
    }
}

extension AppLockManager {
    var biometryDisplayName: String {
        biometryKind.displayName
    }

    var biometryAvailabilityMessage: String? {
        guard case .unavailable(let reason) = biometricAvailability else { return nil }
        return reason.message
    }

    var lastErrorMessage: String? {
        lastFailure?.message
    }
}
