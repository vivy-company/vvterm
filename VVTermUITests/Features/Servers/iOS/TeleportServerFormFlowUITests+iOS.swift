#if os(iOS)
import XCTest

final class TeleportServerFormFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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

        let values = [
            ("vvterm.serverForm.teleport.cluster", "root.example.test"),
            ("vvterm.serverForm.teleport.nodeID", "teleport-ui-node"),
            ("vvterm.serverForm.username", "deploy"),
            ("vvterm.serverForm.teleport.proxy", "https://teleport.example.invalid"),
            ("vvterm.serverForm.teleport.account", "test-user"),
            ("vvterm.serverForm.teleport.connector", "test-sso")
        ]
        for (index, pair) in values.enumerated() {
            enter(app.textFields[pair.0], with: pair.1, in: app, scrollingUp: index != 0)
        }
        XCTAssertFalse(app.textFields["vvterm.serverForm.host"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["vvterm.serverForm.authMethod"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        let add = app.navigationBars["Add Server"].buttons["Add"]
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(app.textFields["vvterm.serverForm.name"].waitForNonExistence(timeout: 10))

        let row = app.descendants(matching: .any)["vvterm.serverDuplicateTest.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Server"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["vvterm.serverForm.name"].value as? String, "Teleport UI Node")
        for (index, pair) in values.enumerated() {
            let field = app.textFields[pair.0]
            reveal(field, in: app, scrollingUp: index != 0)
            XCTAssertEqual(field.value as? String, pair.1)
        }
        XCTAssertFalse(app.textFields["vvterm.serverForm.host"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        app.navigationBars["Edit Server"].buttons["Cancel"].tap()
    }

    @MainActor
    private func enter(_ field: XCUIElement, with value: String, in app: XCUIApplication, scrollingUp: Bool) {
        reveal(field, in: app, scrollingUp: scrollingUp)
        let current = field.value as? String
        XCTAssertTrue(current?.isEmpty == true || current == field.placeholderValue)
        field.tap()
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingUp: Bool) {
        for _ in 0..<10 where !element.isHittable {
            if scrollingUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
    }
}
#endif
