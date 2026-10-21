#if os(iOS)
import XCTest

final class TeleportServerFormFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCredentialSetupKeepsTheServerDraftOpen() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-server-duplicate-harness", "--vvterm-ui-test-teleport-server-form",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["vvterm.teleport.setupTest.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        reveal(open, in: app, scrollingUp: true)
        open.tap()
        let draftName = app.textFields["vvterm.teleport.setupTest.draftName"]
        XCTAssertTrue(draftName.waitForExistence(timeout: 5))
        draftName.tap()
        draftName.typeText("My Teleport server\n")
        let controls = app.staticTexts["vvterm.teleport.credential.controls"]
        reveal(controls, in: app, scrollingUp: true)
        app.buttons["Teleport verification"].tap()

        for _ in 0..<2 {
            let setup = app.buttons["vvterm.teleport.credential.setup"]
            reveal(setup, in: app, scrollingUp: true)
            XCTAssertTrue(setup.isEnabled)
            setup.tap()
            let credentialName = app.textFields["vvterm.teleport.credential.name"]
            XCTAssertTrue(credentialName.waitForExistence(timeout: 5))
            XCTAssertFalse(app.secureTextFields["vvterm.teleport.password"].exists)
            XCTAssertTrue(draftName.exists, "Setup must stay inside Add Server")
            XCTAssertEqual(draftName.value as? String, "My Teleport server")
            let enable = app.buttons["vvterm.teleport.credential.enable"]
            reveal(enable, in: app, scrollingUp: true)
            XCTAssertFalse(enable.isEnabled, "Setup needs a fresh authenticator code")
            let code = app.secureTextFields["vvterm.teleport.credential.otp"]
            reveal(code, in: app, scrollingUp: false)
            code.tap()
            code.typeText("123456\n")
            reveal(enable, in: app, scrollingUp: true)
            XCTAssertTrue(enable.isEnabled)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Compact device setup"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let cancel = app.buttons["vvterm.teleport.credential.cancel"]
            reveal(cancel, in: app, scrollingUp: true)
            cancel.tap()
            XCTAssertTrue(credentialName.waitForNonExistence(timeout: 5))
            reveal(draftName, in: app, scrollingUp: false)
            XCTAssertEqual(draftName.value as? String, "My Teleport server")
        }
    }

    @MainActor
    func testSignInShowsOnlyTheSelectedMethod() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-server-duplicate-harness", "--vvterm-ui-test-teleport-server-form",
            "--vvterm-ui-test-teleport-sign-in", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["vvterm.teleport.setupTest.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        reveal(open, in: app, scrollingUp: true)
        open.tap()

        let password = app.secureTextFields["vvterm.teleport.password"]
        let code = app.secureTextFields["vvterm.teleport.otp"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertTrue(code.exists)
        XCTAssertFalse(app.buttons["vvterm.teleport.credential.remove"].exists)
        password.tap()
        password.typeText("ui-only-password\n")
        let filledPassword = password.value as? String
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Compact sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        code.tap()
        code.typeText("123456\n")

        let method = app.descendants(matching: .any).matching(identifier: "vvterm.teleport.signInMethod").firstMatch
        method.tap()
        app.buttons["Passkey or security key"].tap()
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
        XCTAssertTrue(password.exists)
        XCTAssertEqual(password.value as? String, filledPassword)

        method.tap()
        app.buttons["This device"].tap()
        XCTAssertTrue(password.exists)
        XCTAssertEqual(password.value as? String, filledPassword)
        XCTAssertFalse(code.exists)
        XCTAssertEqual(app.secureTextFields.count, 1)
        XCTAssertTrue(app.buttons["vvterm.teleport.signIn"].isEnabled)
        method.tap()
        app.buttons["Authenticator code"].tap()
        reveal(code, in: app, scrollingUp: false)
        XCTAssertTrue(code.exists)
        XCTAssertTrue(password.exists)
        XCTAssertEqual(password.value as? String, filledPassword)
        XCTAssertTrue((code.value as? String) == code.placeholderValue || (code.value as? String) == "")
    }

    @MainActor
    func testTeleportMetadataCanBeSavedBeforeSignInAndReopened() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-server-duplicate-harness", "--vvterm-ui-test-teleport-server-form",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        let create = app.buttons["vvterm.teleportFormTest.add"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.navigationBars["Add Server"].waitForExistence(timeout: 10))

        enter(app.textFields["vvterm.serverForm.name"], with: "Teleport UI Node", in: app, scrollingUp: false)
        let transport = app.descendants(matching: .any).matching(identifier: "vvterm.serverForm.transport").firstMatch
        reveal(transport, in: app, scrollingUp: true)
        transport.tap()
        let teleport = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Teleport")).firstMatch
        XCTAssertTrue(teleport.waitForExistence(timeout: 5))
        teleport.tap()

        XCTAssertFalse(app.textFields["vvterm.serverForm.teleport.cluster"].exists)
        XCTAssertFalse(app.textFields["vvterm.serverForm.teleport.nodeID"].exists)
        let advanced = app.buttons["vvterm.serverForm.teleport.advanced"]
        reveal(advanced, in: app, scrollingUp: true)
        advanced.tap()
        let values = [
            ("vvterm.serverForm.teleport.proxy", "https://teleport.example.invalid"),
            ("vvterm.serverForm.teleport.account", "test-user"),
            ("vvterm.serverForm.teleport.cluster", "root.example.test"),
            ("vvterm.serverForm.teleport.nodeID", "teleport-ui-node"),
            ("vvterm.serverForm.username", "deploy"),
            ("vvterm.serverForm.teleport.connector", "test-sso")
        ]
        for (index, pair) in values.enumerated() {
            enter(app.textFields[pair.0], with: pair.1, in: app, scrollingUp: index != 0)
        }
        XCTAssertFalse(app.textFields["vvterm.serverForm.host"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.serverForm.authMethod"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        let add = app.buttons["Add"]
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(app.textFields["vvterm.serverForm.name"].waitForNonExistence(timeout: 10))

        let row = app.descendants(matching: .any)["vvterm.serverDuplicateTest.row"]
        reveal(row, in: app, scrollingUp: true)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Server"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["vvterm.serverForm.name"].value as? String, "Teleport UI Node")
        reveal(advanced, in: app, scrollingUp: true)
        advanced.tap()
        for (index, pair) in values.enumerated() {
            let field = app.textFields[pair.0]
            reveal(field, in: app, scrollingUp: index != 0)
            XCTAssertEqual(field.value as? String, pair.1)
        }
        XCTAssertFalse(app.textFields["vvterm.serverForm.host"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        app.buttons["Cancel"].tap()
        checkLocalCredentialRecovery(in: app)
    }

    @MainActor
    private func checkLocalCredentialRecovery(in app: XCUIApplication) {
        let controls = app.staticTexts["vvterm.teleport.credential.controls"]
        reveal(controls, in: app, scrollingUp: false)
        let manage = app.buttons["Teleport verification"]
        manage.tap()
        let setup = app.buttons["vvterm.teleport.credential.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertFalse(setup.isEnabled, "Setup needs a valid signed-in identity")
        let remove = app.buttons["vvterm.teleport.credential.remove"]
        reveal(remove, in: app, scrollingUp: true)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled)
        remove.tap()
        let warning = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Access stays valid. Keep another sign-in method. Remove the device entry in Teleport before setup again."
        )).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove local key"].exists)
        let cancel = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first { $0.isHittable }
        if let cancel {
            cancel.tap()
        } else {
            // Native popover confirmations omit Cancel. A tap outside closes them.
            app.navigationBars["Server Duplicate Test"].tap()
        }
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        XCTAssertTrue(manage.isEnabled)
    }

    @MainActor
    private func enter(_ field: XCUIElement, with value: String, in app: XCUIApplication, scrollingUp: Bool) {
        reveal(field, in: app, scrollingUp: scrollingUp)
        let current = field.value as? String
        XCTAssertTrue(current?.isEmpty == true || current == field.placeholderValue)
        field.tap()
        field.typeText(value + "\n")
        XCTAssertEqual(field.value as? String, value)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingUp: Bool) {
        for _ in 0..<10 where !element.isHittable {
            if scrollingUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
#endif
