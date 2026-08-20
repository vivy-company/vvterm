import Combine
import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class AppLockManagerTests: XCTestCase {
    private final class AppLockPreferencesFake: AppLockPreferences {
        var fullAppLockEnabled: Bool?
        var lockOnBackground: Bool?
        var authGraceSeconds: Int?
    }

    private final class StubBiometricAuthService: BiometricAuthServing {
        var availabilityResult: BiometricAvailability
        var authenticateError: Error?
        private(set) var authenticateReasons: [BiometricAuthenticationReason] = []

        init(availabilityResult: BiometricAvailability) {
            self.availabilityResult = availabilityResult
        }

        func availability() -> BiometricAvailability {
            availabilityResult
        }

        func authenticate(
            reason: BiometricAuthenticationReason,
            allowPasscodeFallback: Bool
        ) async throws {
            authenticateReasons.append(reason)
            if let authenticateError {
                throw authenticateError
            }
        }
    }

    private final class DelayedBiometricAuthService: BiometricAuthServing {
        let availabilityResult: BiometricAvailability
        private(set) var authenticateReasons: [BiometricAuthenticationReason] = []

        private let startedStream: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private var authenticationContinuation: CheckedContinuation<Void, Error>?

        init(availabilityResult: BiometricAvailability) {
            self.availabilityResult = availabilityResult
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.startedStream = started.stream
            self.startedContinuation = started.continuation
        }

        func availability() -> BiometricAvailability {
            availabilityResult
        }

        func authenticate(
            reason: BiometricAuthenticationReason,
            allowPasscodeFallback: Bool
        ) async throws {
            authenticateReasons.append(reason)
            startedContinuation.yield()
            try await withCheckedThrowingContinuation { continuation in
                authenticationContinuation = continuation
            }
        }

        func waitUntilAuthenticationStarts() async {
            for await _ in startedStream {
                return
            }
        }

        func succeed() {
            authenticationContinuation?.resume()
            authenticationContinuation = nil
        }
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "VVTermTests.AppLockManager.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testEnableFullAppLockRequiresAvailableBiometry() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .unavailable(.notAvailable)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertFalse(manager.fullAppLockEnabled)
        XCTAssertEqual(manager.lastFailure, .biometryUnavailable(.notAvailable))
        XCTAssertEqual(
            manager.lastErrorMessage,
            String(localized: "Biometric authentication is unavailable on this device.")
        )
        XCTAssertTrue(authService.authenticateReasons.isEmpty)
    }

    func testInjectedPreferencesClockAndIDOwnInitialAndUnlockedState() async {
        let preferences = AppLockPreferencesFake()
        preferences.fullAppLockEnabled = true
        preferences.lockOnBackground = false
        preferences.authGraceSeconds = 45
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let generation = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let now = Date(timeIntervalSinceReferenceDate: 12_345)
        let manager = AppLockManager(
            dependencies: AppLockManagerDependencies(
                preferences: preferences,
                authService: authService,
                now: { now },
                makeID: { generation }
            )
        )

        XCTAssertEqual(manager.lockState, .locked(generation: generation))
        XCTAssertFalse(manager.lockOnBackground)
        XCTAssertEqual(manager.authGraceSeconds, 45)

        let didUnlock = await manager.ensureAppUnlocked()

        XCTAssertTrue(didUnlock)
        XCTAssertEqual(manager.lockState, .unlocked(at: now))
        manager.lockOnBackground = true
        XCTAssertEqual(preferences.lockOnBackground, true)
    }

    func testUserDefaultsPreferencesRoundTripAndRemoveValues() {
        let defaults = makeDefaults()
        let preferences = UserDefaultsAppLockPreferences(defaults: defaults)

        XCTAssertNil(preferences.fullAppLockEnabled)
        XCTAssertNil(preferences.lockOnBackground)
        XCTAssertNil(preferences.authGraceSeconds)

        preferences.fullAppLockEnabled = true
        preferences.lockOnBackground = false
        preferences.authGraceSeconds = 120

        XCTAssertEqual(preferences.fullAppLockEnabled, true)
        XCTAssertEqual(preferences.lockOnBackground, false)
        XCTAssertEqual(preferences.authGraceSeconds, 120)

        preferences.fullAppLockEnabled = nil
        preferences.lockOnBackground = nil
        preferences.authGraceSeconds = nil

        XCTAssertNil(preferences.fullAppLockEnabled)
        XCTAssertNil(preferences.lockOnBackground)
        XCTAssertNil(preferences.authGraceSeconds)
    }

    func testEnableFullAppLockAuthenticatesAndUnlocksApp() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertTrue(manager.fullAppLockEnabled)
        XCTAssertFalse(manager.isAppLocked)
        XCTAssertEqual(authService.authenticateReasons, [.enableAppLock(biometry: .faceID)])
    }

    func testDisableFullAppLockRequiresFreshAuthentication() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(false)

        XCTAssertFalse(manager.fullAppLockEnabled)
        XCTAssertEqual(authService.authenticateReasons, [.disableAppLock])
    }

    func testDisableFullAppLockDenialKeepsItEnabled() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.authenticateError = BiometricAuthenticationFailure.cancelled
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(false)

        XCTAssertTrue(manager.fullAppLockEnabled)
        XCTAssertEqual(authService.authenticateReasons, [.disableAppLock])
        XCTAssertNil(manager.lastFailure)
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testProtectedServerActionsAlwaysRequireFreshAuthentication() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = Server(
            workspaceId: UUID(),
            name: "Protected",
            host: "example.com",
            username: "root",
            requiresBiometricUnlock: true
        )

        let didAuthorizeEdit = await manager.authorizeProtectedServerAction(server, action: .edit)
        let didAuthorizeSave = await manager.authorizeProtectedServerAction(server, action: .save)

        XCTAssertTrue(didAuthorizeEdit)
        XCTAssertTrue(didAuthorizeSave)
        XCTAssertEqual(
            authService.authenticateReasons,
            [
                .protectedServerAction(action: .edit, serverName: "Protected"),
                .protectedServerAction(action: .save, serverName: "Protected")
            ]
        )
    }

    func testProtectedServerActionDenialReturnsFalse() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.authenticateError = BiometricAuthenticationFailure.cancelled
        let manager = AppLockManager(defaults: defaults, authService: authService)
        let server = Server(
            workspaceId: UUID(),
            name: "Protected",
            host: "example.com",
            username: "root",
            requiresBiometricUnlock: true
        )

        let didAuthorize = await manager.authorizeProtectedServerAction(server, action: .delete)

        XCTAssertFalse(didAuthorize)
        XCTAssertEqual(
            authService.authenticateReasons,
            [.protectedServerAction(action: .delete, serverName: "Protected")]
        )
        XCTAssertNil(manager.lastFailure)
    }

    func testNewBackgroundLockRejectsPendingAuthenticationSuccess() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = DelayedBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        let unlockTask = Task { await manager.ensureAppUnlocked() }
        await authService.waitUntilAuthenticationStarts()
        XCTAssertTrue(manager.isAuthenticating)

        manager.lockAppNow()
        authService.succeed()

        let didUnlock = await unlockTask.value
        XCTAssertFalse(didUnlock)
        XCTAssertTrue(manager.isAppLocked)
        XCTAssertFalse(manager.isAuthenticating)
        XCTAssertEqual(manager.authenticationState, .idle)
    }

    func testGraceSecondsClampToUpperBound() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        manager.authGraceSeconds = 900

        XCTAssertEqual(manager.authGraceSeconds, 300)
    }

    func testSceneActivationDoesNotPublishWhenBiometryAvailabilityIsUnchanged() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)
        var publicationCount = 0
        let cancellable = manager.objectWillChange.sink {
            publicationCount += 1
        }

        manager.handleSceneActivation()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testBiometryValuesAreDerivedFromAvailability() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        XCTAssertEqual(manager.biometricAvailability, .available(.touchID))
        XCTAssertTrue(manager.isBiometryAvailable)
        XCTAssertEqual(manager.biometryKind, .touchID)
        XCTAssertNil(manager.biometryAvailabilityMessage)

        authService.availabilityResult = .unavailable(.notEnrolled)
        manager.refreshBiometryAvailability()

        XCTAssertEqual(manager.biometricAvailability, .unavailable(.notEnrolled))
        XCTAssertFalse(manager.isBiometryAvailable)
        XCTAssertEqual(manager.biometryKind, .none)
        XCTAssertEqual(
            manager.biometryAvailabilityMessage,
            String(localized: "Biometric authentication is not set up on this device.")
        )
    }

    func testTaskCancellationDoesNotPublishFailure() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        authService.authenticateError = CancellationError()
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertFalse(manager.fullAppLockEnabled)
        XCTAssertNil(manager.lastFailure)
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testAuthenticationFailureIsExposedAsSemanticState() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        authService.authenticateError = BiometricAuthenticationFailure.locked
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertEqual(manager.lastFailure, .authentication(.locked))
        XCTAssertEqual(
            manager.lastErrorMessage,
            String(localized: "Biometric authentication is locked. Unlock the device and try again.")
        )
    }
}
