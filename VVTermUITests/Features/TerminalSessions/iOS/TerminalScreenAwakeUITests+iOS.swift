#if os(iOS)
import XCTest

final class TerminalScreenAwakeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTerminalSettingControlsIdleTimerAndRestoresAfterBackground() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-screen-awake-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.screenAwakeTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        let toggle = keepScreenAwakeToggle(in: app, diagnostics: diagnostics)
        if diagnostics.label.contains("preference=false") {
            tapTrailingSwitch(in: toggle)
            wait(
                for: diagnostics,
                containing: "preference=true idleTimerDisabled=true",
                app: app
            )
        }

        tapTrailingSwitch(in: toggle)
        wait(
            for: diagnostics,
            containing: "preference=false idleTimerDisabled=false",
            app: app
        )

        tapTrailingSwitch(in: toggle)
        wait(
            for: diagnostics,
            containing: "preference=true idleTimerDisabled=true",
            app: app
        )

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackgroundState(of: app, timeout: 8), diagnostics.label)

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        wait(
            for: diagnostics,
            containing: "idleTimerDisabled=true backgroundReleased=true",
            app: app
        )
    }

    @MainActor
    private func keepScreenAwakeToggle(
        in app: XCUIApplication,
        diagnostics: XCUIElement
    ) -> XCUIElement {
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "vvterm.settings.terminal.keepScreenAwake")
            .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), diagnostics.label)
        return toggle
    }

    @MainActor
    private func tapTrailingSwitch(in toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
    }

    @MainActor
    private func wait(
        for diagnostics: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 8,
        app: XCUIApplication
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if diagnostics.exists, diagnostics.label.contains(expected) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected diagnostics to contain '\(expected)'; got '\(diagnostics.label)'; app state=\(app.state.rawValue)")
    }

    @MainActor
    private func waitForBackgroundState(
        of app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
#endif
