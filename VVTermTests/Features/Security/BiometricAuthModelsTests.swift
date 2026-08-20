import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class BiometricAuthModelsTests: XCTestCase {
    func testCancelledFailureHasNoPresentationAndIsMarkedCancellation() {
        let failure = BiometricAuthenticationFailure.cancelled

        XCTAssertNil(failure.message)
        XCTAssertTrue(failure.isCancellation)
    }

    func testFailurePresentationPreservesExistingLocalizedCopy() {
        XCTAssertEqual(
            BiometricAuthenticationFailure.notEnrolled.message,
            String(localized: "Biometric authentication is not set up on this device.")
        )
        XCTAssertEqual(
            BiometricAuthenticationFailure.notAvailable.message,
            String(localized: "Biometric authentication is unavailable on this device.")
        )
        XCTAssertEqual(
            BiometricAuthenticationFailure.locked.message,
            String(localized: "Biometric authentication is locked. Unlock the device and try again.")
        )
        XCTAssertEqual(
            BiometricAuthenticationFailure.passcodeNotSet.message,
            String(localized: "Set a device passcode before using biometric authentication.")
        )
        XCTAssertEqual(
            BiometricAuthenticationFailure.authenticationFailed.message,
            String(localized: "Authentication failed.")
        )
        XCTAssertEqual(
            BiometricAuthenticationFailure.system(message: "System failure").message,
            "System failure"
        )
    }

    func testAvailabilityPresentationPreservesExistingLocalizedCopy() {
        XCTAssertEqual(
            BiometricUnavailability.notEnrolled.message,
            String(localized: "Biometric authentication is not set up on this device.")
        )
        XCTAssertEqual(
            BiometricUnavailability.notAvailable.message,
            String(localized: "Biometric authentication is unavailable on this device.")
        )
        XCTAssertEqual(
            BiometricUnavailability.locked.message,
            String(localized: "Biometric authentication is locked. Unlock the device to try again.")
        )
        XCTAssertEqual(
            BiometricUnavailability.passcodeNotSet.message,
            String(localized: "Set a device passcode before using biometric authentication.")
        )
        XCTAssertEqual(
            BiometricUnavailability.system(message: "System unavailable").message,
            "System unavailable"
        )
    }
}
