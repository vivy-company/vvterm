#if os(iOS)
import XCTest

final class TeleportConnectionSignInFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testExpiredAccessOpensSignInWithSavedPasswordAndCancelStopsConnection() {
        let app = launchHarness()
        defer { app.terminate() }
        openSignIn(in: app)

        let password = app.secureTextFields["vvterm.teleport.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        let signIn = app.buttons["vvterm.teleport.signIn"]
        let passwordLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in signIn.isEnabled }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [passwordLoaded], timeout: 5), .completed)
        XCTAssertNotEqual(password.value as? String, "Password")
        XCTAssertFalse((password.value as? String ?? "").isEmpty)
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertTrue(app.secureTextFields["vvterm.teleport.otp"].exists)
        XCTAssertEqual(app.textFields.count, 0, "Renewal must not edit the saved server")
        XCTAssertFalse(app.buttons["vvterm.teleport.node"].exists)
        XCTAssertFalse(app.buttons["vvterm.teleport.login"].exists)
        XCTAssertFalse(app.buttons["vvterm.teleport.credential.setup"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Teleport connection sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.navigationBars["Sign in to Teleport"].buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["cancelled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Sign in to Teleport"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.teleport.renewalTest.connect"].isEnabled)
    }

    @MainActor
    func testApprovedStoredAccessResumesConnectionAndClosesSignIn() {
        let app = launchHarness()
        defer { app.terminate() }
        openSignIn(in: app)

        app.buttons["vvterm.teleport.renewalTest.finish"].tap()

        XCTAssertTrue(app.staticTexts["connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Sign in to Teleport"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.teleport.renewalTest.connect"].isEnabled)
    }

    @MainActor
    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-teleport-connection-sign-in",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func openSignIn(in app: XCUIApplication) {
        let connect = app.buttons["vvterm.teleport.renewalTest.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.navigationBars["Sign in to Teleport"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Renewal UI server"].exists)
        XCTAssertTrue(app.staticTexts["ui-test-user"].exists)
    }
}
#endif
