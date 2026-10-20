import Foundation
import TeleportKit
import Testing
@testable import VVTerm

struct TeleportAccessErrorTests {
    @Test
    func errorMessagesNeverIncludeAnUntrustedReason() {
        let reason = "PRIVATE_VALUE_MUST_NOT_APPEAR_7f492dd4"
        let errors: [any Error] = [
            TeleportError.invalidConfiguration(reason),
            TeleportError.invalidResponse(reason),
            TeleportError.invalidCertificate(reason),
            TeleportError.limitExceeded(reason),
            TeleportError.transport(reason),
            SSHError.connectionFailed(reason),
            NSError(domain: reason, code: 1, userInfo: [NSLocalizedDescriptionKey: reason]),
        ]
        for error in errors {
            let message = TeleportAccessError.message(for: error)
            #expect(!message.isEmpty)
            #expect(!message.contains(reason))
        }
    }

    @Test
    func authorizationAndTrustFailuresKeepTheirSafeActionableMessages() {
        let denied = TeleportAccessError.message(for: TeleportError.accessDenied)
        #expect(TeleportAccessError.message(for: TeleportError.httpStatus(401)) == denied)
        #expect(TeleportAccessError.message(for: TeleportError.httpStatus(403)) == denied)
        #expect(TeleportAccessError.message(for: TeleportError.authenticationRequired) != denied)
        #expect(TeleportAccessError.message(for: TeleportError.invalidCertificate("untrusted")) != denied)
    }

    @Test
    func unavailableBrowserMFAUsesTheFixedPolicyMessage() {
        #expect(TeleportAccessError.message(for: TeleportError.unsupportedPolicy(.browserMFA))
            == TeleportAccessError.message(for: TeleportError.unsupportedPolicy(.hardwareKey)))
    }

    @Test
    func deviceFailuresGiveDifferentSafeRecoveryActions() {
        let errors: [TeleportError] = [
            .secureEnclaveUnavailable, .biometricsUnavailable, .deviceCredentialMissing,
            .deviceCredentialExists, .deviceCredentialStorage,
        ]
        let messages = errors.map(TeleportAccessError.message(for:))
        #expect(Set(messages).count == errors.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(TeleportAccessError.message(for: TeleportError.unsupportedPolicy(.authenticatorRequirements))
            == TeleportAccessError.message(for: TeleportError.unsupportedPolicy(.hardwareKey)))
    }
}
