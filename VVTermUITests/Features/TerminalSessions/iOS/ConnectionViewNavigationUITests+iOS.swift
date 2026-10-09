#if os(iOS)
import XCTest

final class ConnectionViewNavigationUITests: TerminalReconnectUITestCase {
    @MainActor
    func testFilesOptionsKeepCommandsInOneMenu() throws {
        let (app, _) = launchProductionSSHTestHarness()
        defer { app.terminate() }
        let picker = app.segmentedControls.firstMatch
        if picker.exists {
            picker.buttons.containing(.image, identifier: "folder").firstMatch.tap()
        } else {
            app.buttons["vvterm.connectionView.files"].tap()
        }
        let options = app.buttons["vvterm.terminal.moreMenu"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(options.isHittable)
        XCTAssertLessThanOrEqual(options.frame.width, 60)
        options.tap()
        for title in ["Upload", "New Folder", "Copy Path"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testHorizontalViewPickerStaysCenteredWhenFilesAddsSearch() throws {
        guard #available(iOS 27.1, *) else {
            throw XCTSkip("This toolbar applies to iOS 27.1 and later.")
        }
        let (app, _) = launchProductionSSHTestHarness()
        defer { app.terminate() }
        let picker = app.segmentedControls.firstMatch
        guard picker.waitForExistence(timeout: 5) else {
            throw XCTSkip("This test needs a horizontal toolbar.")
        }
        let initialFrame = picker.frame
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.exists)
        XCTAssertEqual(initialFrame.midX, navigationBar.frame.midX, accuracy: 1)
        let files = picker.buttons.containing(.image, identifier: "folder").firstMatch
        let terminal = picker.buttons.containing(.image, identifier: "terminal").firstMatch
        for _ in 0..<2 {
            files.tap()
            XCTAssertTrue(files.isSelected)
            XCTAssertEqual(picker.frame.minX, initialFrame.minX, accuracy: 1,
                           "Files search must not move the view picker.")
            terminal.tap()
            XCTAssertTrue(terminal.isSelected)
            XCTAssertEqual(picker.frame.minX, initialFrame.minX, accuracy: 1)
        }
    }

    @MainActor
    func testViewPickerFollowsSystemToolbarAxisAndPreservesTerminal() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "--vvterm-ui-test-view-picker",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }
        let terminal = app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        let diagnostics = app.staticTexts["vvterm.viewPickerTest.selection"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))

        if diagnostics.label.hasPrefix("vertical") {
            XCTAssertFalse(app.segmentedControls.firstMatch.exists,
                           "The view picker must not keep a horizontal bar when the system uses side controls.")
            let stats = app.buttons["vvterm.connectionView.stats"]
            let files = app.buttons["vvterm.connectionView.files"]
            let terminalButton = app.buttons["vvterm.connectionView.terminal"]
            XCTAssertTrue(stats.waitForExistence(timeout: 5))
            XCTAssertTrue(files.isHittable)
            XCTAssertTrue(terminalButton.isHittable)
            XCTAssertEqual(stats.frame.midX, files.frame.midX, accuracy: 1)
            XCTAssertEqual(stats.frame.midX, terminalButton.frame.midX, accuracy: 1)
            XCTAssertLessThan(stats.frame.maxY, terminalButton.frame.maxY)
            XCTAssertLessThan(terminalButton.frame.maxY, files.frame.maxY)
            let menu = app.buttons["vvterm.terminal.moreMenu"]
            let add = app.buttons["vvterm.viewPickerTest.add"]
            XCTAssertTrue(menu.isHittable)
            XCTAssertTrue(add.isHittable)
            XCTAssertGreaterThan(add.frame.minY - files.frame.maxY,
                                 terminalButton.frame.minY - stats.frame.maxY,
                                 "Actions must have more space from destinations than destinations have from each other.")
            XCTAssertGreaterThan(add.frame.midY, app.frame.minY + app.frame.height * 0.75,
                                 "Add must remain at the bottom of the side bar.")
            XCTAssertGreaterThan(menu.frame.midY, add.frame.midY)
            files.tap()
            assertSelection("vertical files", diagnostics: diagnostics)
            terminalButton.tap()
            assertSelection("vertical terminal", diagnostics: diagnostics)
            XCTAssertTrue(terminal.exists)
        } else {
            let picker = app.segmentedControls.firstMatch
            XCTAssertTrue(picker.exists)
            picker.buttons.containing(.image, identifier: "folder").firstMatch.tap()
            assertSelection("horizontal files", diagnostics: diagnostics)
            picker.buttons.containing(.image, identifier: "terminal").firstMatch.tap()
            assertSelection("horizontal terminal", diagnostics: diagnostics)
            XCTAssertTrue(terminal.exists)
        }
    }

    @MainActor
    private func assertSelection(_ value: String, diagnostics: XCUIElement) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", value), object: diagnostics
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
}
#endif
