#if os(iOS)
import XCTest

final class TerminalZenModeUITests: XCTestCase {
    @MainActor
    func testRealTerminalLauncherOpensZenPanel() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertEqual(launcher.frame.width, launcher.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(launcher.frame.width, 48)
        launcher.tap()

        XCTAssertTrue(
            app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5),
            "Zen launcher remained visible but did not open the control panel"
        )
    }

    @MainActor
    func testMenuEntryHidesChromeAndFloatingControlRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        app.launch()

        let chrome = app.buttons["vvterm.zenTest.chrome"]
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(chrome.waitForNonExistence(timeout: 5))

        app.buttons["vvterm.zen.controls"].tap()
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.files"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.newTab"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.settings"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.editServer"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.back"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.disconnect"].exists)

        app.buttons["vvterm.terminal.zen.view.files"].tap()
        XCTAssertTrue(app.buttons["vvterm.zen.controls"].exists)

        let exitZenMode = app.buttons["vvterm.terminal.exitZenMode"]
        XCTAssertTrue(exitZenMode.waitForExistence(timeout: 5))
        if !exitZenMode.isHittable {
            app.scrollViews["vvterm.terminal.zenPanel"].swipeUp()
        }
        XCTAssertTrue(exitZenMode.isHittable)
        exitZenMode.tap()

        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForNonExistence(timeout: 5)
        )
    }
}
#endif
