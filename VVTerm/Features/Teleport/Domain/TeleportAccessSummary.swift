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

nonisolated enum TeleportAccessError: Error, Equatable {
    case loginInProgress
    case localAccountsOnly

    static func message(for error: any Error) -> String {
        if (error as? URLError)?.code == .timedOut {
            return String(localized: "Sign-in timed out. Try again.")
        }
        if let accessError = error as? TeleportAccessError {
            switch accessError {
            case .loginInProgress:
                return String(localized: "This Teleport profile is signing in. Finish or cancel it, then try again.")
            case .localAccountsOnly:
                return String(localized: "VVTerm supports local Teleport accounts only.")
            }
        }
        guard let error = error as? TeleportError else {
            return String(localized: "Teleport connection failed. Check the profile and sign in again.")
        }
        switch error {
        case .transport("browser login timeout"):
            return String(localized: "Sign-in timed out. Try again.")
        case .transport("browser could not start"):
            return String(localized: "The approval browser could not open. Try again.")
        case .oneTimeCodeRequired:
            return String(localized: "This server requires a sign-in method that VVTerm does not support. Contact your administrator.")
        case .authenticationRequired:
            return String(localized: "Sign in to this Teleport profile before connecting.")
        case .accessDenied, .httpStatus(401), .httpStatus(403):
            return String(localized: "Teleport denied access. Check the account and node permissions.")
        case .unsupportedPolicy(.browserMFA):
            return String(localized: "Browser approval is not available for this account. Check your registered passkeys and server settings.")
        case .unsupportedPolicy, .unsupportedVersion:
            return String(localized: "This Teleport server or policy is not supported. Contact your administrator.")
        case .invalidCertificate:
            return String(localized: "Teleport certificate validation failed. Check the proxy, account, and cluster.")
        case .nodeNotFound:
            return String(localized: "The Teleport node was not found. Choose its exact node ID again.")
        case .ambiguousNode:
            return String(localized: "More than one Teleport node has this name. Use its exact node ID.")
        case .secureEnclaveUnavailable:
            return String(localized: "Secure Enclave is not available on this device.")
        case .biometricsUnavailable:
            return String(localized: "Face ID or Touch ID is not available. Check system settings.")
        case .deviceCredentialMissing:
            return String(localized: "This device key cannot be used. Remove it from this device and Teleport, then sign in again.")
        case .deviceCredentialExists:
            return String(localized: "A device key already exists. Remove it from this device and Teleport, then sign in again.")
        case .deviceCredentialStorage:
            return String(localized: "Device key storage failed. Check Teleport for a failed setup entry before you try again.")
        default:
            return String(localized: "Teleport connection failed. Check the profile and sign in again.")
        }
    }
}
