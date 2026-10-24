#if os(iOS)
import XCTest

final class TeleportConnectionSignInFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testProtectedExpiredAccessUsesCombinedApprovalWithNoGracePeriod() {
        let app = launchHarness()
        defer { app.terminate() }
        connect(in: app)

        XCTAssertTrue(app.staticTexts["connected"].waitForExistence(timeout: 5))
        assertNoSignInForm(in: app)
        XCTAssertTrue(app.buttons["vvterm.teleport.renewalTest.connect"].isEnabled)
    }

    @MainActor
    func testFailedAuthenticationOffersCancelWithoutOpeningConnection() {
        let app = launchHarness(failFirst: true)
        defer { app.terminate() }
        connect(in: app)

        let alert = app.alerts["Teleport sign-in failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Retry"].exists)
        assertNoSignInForm(in: app)
        alert.buttons["Cancel"].tap()

        XCTAssertTrue(app.staticTexts["cancelled"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["connected"].exists)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.teleport.renewalTest.connect"].isEnabled)
    }

    @MainActor
    func testRetryAuthenticatesThePendingConnectionWithoutAnAppSheet() {
        let app = launchHarness(failFirst: true)
        defer { app.terminate() }
        connect(in: app)

        let alert = app.alerts["Teleport sign-in failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Retry"].tap()

        XCTAssertTrue(app.staticTexts["connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        assertNoSignInForm(in: app)
    }

    @MainActor
    private func launchHarness(failFirst: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-teleport-connection-sign-in",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO",
            "-security.authGraceSeconds", "0"
        ]
        if failFirst { app.launchArguments.append("--vvterm-ui-test-teleport-renewal-failure") }
        app.launch()
        return app
    }

    @MainActor
    private func connect(in app: XCUIApplication) {
        let connect = app.buttons["vvterm.teleport.renewalTest.connect"]
        let hasConnect = connect.waitForExistence(timeout: 10)
        if !hasConnect {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Teleport renewal launch failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Teleport renewal launch hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(hasConnect)
        connect.tap()
    }

    @MainActor
    private func assertNoSignInForm(in app: XCUIApplication) {
        XCTAssertFalse(app.navigationBars["Sign in to Teleport"].exists)
        XCTAssertFalse(app.buttons["vvterm.teleport.signIn"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        XCTAssertEqual(app.textFields.count, 0)
    }
}
#endif
