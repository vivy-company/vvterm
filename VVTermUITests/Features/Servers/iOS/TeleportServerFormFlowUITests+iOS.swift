#if os(iOS)
import XCTest

final class TeleportServerFormFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDeviceKeyRecoveryKeepsTheServerDraftOpen() {
        let app = launchControls()
        defer { app.terminate() }
        let draftName = app.textFields["vvterm.teleport.setupTest.draftName"]
        XCTAssertTrue(draftName.waitForExistence(timeout: 5))
        draftName.tap()
        draftName.typeText("My Teleport server\n")

        for _ in 0..<2 {
            checkLocalCredentialRecovery(in: app)
            XCTAssertTrue(draftName.exists, "Recovery must stay inside Add Server")
            reveal(draftName, in: app, scrollingUp: false)
            XCTAssertEqual(draftName.value as? String, "My Teleport server")
            XCTAssertFalse(app.secureTextFields.firstMatch.exists)
            XCTAssertFalse(app.textFields["vvterm.teleport.credential.name"].exists)
        }
    }

    @MainActor
    func testSignInUsesOneActionWithoutAppPasswordOrCodeFields() {
        let app = launchControls(signIn: true)
        defer { app.terminate() }
        let signIn = app.buttons["vvterm.teleport.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.teleport.signInMethod"].exists)
        XCTAssertFalse(app.buttons["vvterm.teleport.credential.setup"].exists)
        XCTAssertFalse(app.buttons["vvterm.teleport.credential.remove"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Teleport sign-in action"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func launchControls(signIn: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-server-duplicate-harness", "--vvterm-ui-test-teleport-server-form",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO"
        ]
        if signIn { app.launchArguments.append("--vvterm-ui-test-teleport-sign-in") }
        app.launch()
        let open = app.buttons["vvterm.teleport.setupTest.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        reveal(open, in: app, scrollingUp: true)
        open.tap()
        return app
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
            ("vvterm.serverForm.teleport.proxy", "teleport.example.invalid"),
            ("vvterm.serverForm.teleport.account", "test-user"),
            ("vvterm.serverForm.teleport.cluster", "root.example.test"),
            ("vvterm.serverForm.teleport.nodeID", "teleport-ui-node"),
            ("vvterm.serverForm.username", "deploy")
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
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Teleport row divider"
        screenshot.lifetime = .keepAlways
        self.add(screenshot)
        row.press(forDuration: 1)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Server"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["vvterm.serverForm.name"].value as? String, "Teleport UI Node")
        reveal(advanced, in: app, scrollingUp: true)
        advanced.tap()
        for (index, pair) in values.enumerated() {
            let field = app.textFields[pair.0]
            reveal(field, in: app, scrollingUp: index != 0)
            let expected = pair.0 == "vvterm.serverForm.teleport.proxy"
                ? "https://teleport.example.invalid" : pair.1
            XCTAssertEqual(field.value as? String, expected)
        }
        XCTAssertFalse(app.textFields["vvterm.serverForm.host"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        app.buttons["Cancel"].tap()
        checkLocalCredentialRecovery(in: app)
    }

    @MainActor
    private func checkLocalCredentialRecovery(in app: XCUIApplication) {
        let remove = app.buttons["vvterm.teleport.credential.remove"]
        reveal(remove, in: app, scrollingUp: true)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled)
        remove.tap()
        let warning = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "The key is removed from this device only. Remove its entry in Teleport before you set up this device again. Issued access stays valid."
        )).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove device key"].exists)
        let cancel = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first { $0.isHittable }
        if let cancel {
            cancel.tap()
        } else {
            let dismissRegion = app.otherElements.matching(identifier: "PopoverDismissRegion")
                .allElementsBoundByIndex.first { $0.isHittable }
            guard let dismissRegion else {
                XCTFail("The confirmation has no visible dismiss control")
                return
            }
            dismissRegion.tap()
        }
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled)
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
