import Foundation
import LocalAuthentication
import XCTest
@testable import VVTerm

@MainActor
final class BiometricAuthServiceTests: XCTestCase {
    func testSemanticReasonsMapToExistingLocalizedContextCopy() {
        XCTAssertEqual(
            BiometricAuthService.localizedReason(for: .enableAppLock(biometry: .faceID)),
            String(
                format: String(localized: "Enable %@ for VVTerm"),
                String(localized: "Face ID")
            )
        )
        XCTAssertEqual(
            BiometricAuthService.localizedReason(for: .disableAppLock),
            String(localized: "Authenticate to disable the VVTerm app lock")
        )
        XCTAssertEqual(
            BiometricAuthService.localizedReason(for: .unlockApp(biometry: .touchID)),
            String(
                format: String(localized: "Unlock VVTerm with %@"),
                String(localized: "Touch ID")
            )
        )
        XCTAssertEqual(
            BiometricAuthService.localizedReason(for: .unlockServer(name: "Production")),
            String(
                format: String(localized: "Unlock server %@"),
                "Production"
            )
        )
        let protectedActions: [(AppLockAuthenticationState.ProtectedServerAction, String)] = [
            (.edit, String(localized: "edit")),
            (.testConnection, String(localized: "test")),
            (.save, String(localized: "save")),
            (.delete, String(localized: "delete"))
        ]
        for (action, actionName) in protectedActions {
            XCTAssertEqual(
                BiometricAuthService.localizedReason(
                    for: .protectedServerAction(action: action, serverName: "Production")
                ),
                String(
                    format: String(localized: "Authenticate to %@ server %@"),
                    actionName,
                    "Production"
                )
            )
        }
    }

    func testCancellationErrorsMapToSemanticCancellation() {
        XCTAssertEqual(
            BiometricAuthService.authenticationFailure(for: CancellationError()),
            .cancelled
        )

        let userCancellation = NSError(
            domain: LAError.errorDomain,
            code: LAError.Code.userCancel.rawValue
        )
        XCTAssertEqual(
            BiometricAuthService.authenticationFailure(for: userCancellation),
            .cancelled
        )
    }

    func testUnknownAuthenticationErrorPreservesSystemMessage() {
        let error = NSError(
            domain: "VVTermTests.BiometricAuth",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "System detail"]
        )

        XCTAssertEqual(
            BiometricAuthService.authenticationFailure(for: error),
            .system(message: "System detail")
        )
    }

    func testUnknownAvailabilityErrorPreservesSystemMessage() {
        let error = NSError(
            domain: "VVTermTests.BiometricAvailability",
            code: 43,
            userInfo: [NSLocalizedDescriptionKey: "System unavailable"]
        )

        XCTAssertEqual(
            BiometricAuthService.unavailability(for: error),
            .system(message: "System unavailable")
        )
    }
}
