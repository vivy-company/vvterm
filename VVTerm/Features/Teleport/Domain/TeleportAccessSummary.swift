import Foundation
import TeleportKit

nonisolated struct TeleportAccessSummary: Sendable {
    let account: String
    let clusterName: String
    let validBefore: Date
    let allowedLogins: [String]
}

extension TeleportAccessSummary {
    nonisolated init(identity: TeleportIdentity) {
        account = identity.username
        clusterName = identity.clusterName
        validBefore = identity.validBefore
        allowedLogins = identity.allowedLogins
    }
}

@MainActor
protocol TeleportBrowserSession: TeleportBrowserPresenter {
    func cancel()
}

nonisolated enum TeleportAccessError: Error {
    case loginInProgress
    case deviceSetupCodeRequired

    static func message(for error: any Error) -> String {
        if let accessError = error as? TeleportAccessError {
            switch accessError {
            case .loginInProgress:
                return String(localized: "This Teleport profile is signing in. Finish or cancel it, then try again.")
            case .deviceSetupCodeRequired:
                return String(localized: "Enter a fresh code from your authenticator app to set up device sign-in. Wait for a new code after login.")
            }
        }
        guard let error = error as? TeleportError else {
            return String(localized: "Teleport connection failed. Check the profile and sign in again.")
        }
        switch error {
        case .oneTimeCodeRequired:
            return message(for: TeleportAccessError.deviceSetupCodeRequired)
        case .authenticationRequired:
            return String(localized: "Sign in to this Teleport profile before connecting.")
        case .accessDenied, .httpStatus(401), .httpStatus(403):
            return String(localized: "Teleport denied access. Check the account, code, and node permissions.")
        case .unsupportedPolicy(.browserMFA):
            return String(localized: "Browser approval is not available for this account. Use a password and code, or check your registered passkeys and server settings.")
        case .unsupportedPolicy, .unsupportedVersion:
            return String(localized: "This Teleport server or policy is not supported. Contact your administrator.")
        case .invalidCertificate:
            return String(localized: "Teleport certificate validation failed. Check the proxy, account, and cluster.")
        case .nodeNotFound:
            return String(localized: "The Teleport node was not found. Choose its exact node ID again.")
        case .ambiguousNode:
            return String(localized: "More than one Teleport node has this name. Use its exact node ID.")
        case .secureEnclaveUnavailable:
            return String(localized: "Secure Enclave is not available. Use another sign-in method.")
        case .biometricsUnavailable:
            return String(localized: "Face ID or Touch ID is not available. Check system settings or sign in another way.")
        case .deviceCredentialMissing:
            return String(localized: "The local device key is missing or cannot be used. Sign in another way. Remove its Teleport entry before setup again.")
        case .deviceCredentialExists:
            return String(localized: "A local credential already exists. Use device biometrics, or remove the local key and its Teleport entry before setup again.")
        case .deviceCredentialStorage:
            return String(localized: "Device credential storage failed. Sign in another way. Check Teleport for a failed setup entry.")
        default:
            return String(localized: "Teleport connection failed. Check the profile and sign in again.")
        }
    }
}
