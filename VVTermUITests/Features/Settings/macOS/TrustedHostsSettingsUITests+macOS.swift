#if os(macOS)
import XCTest

final class TrustedHostsSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRowsShowExactLastUsedDateWithoutActionsButton() {
        let app = launchHarness()
        defer { app.terminate() }

        let rowID = "trusted.example.com:22"
        let row = app.descendants(matching: .any)[
            "vvterm.settings.trustedHosts.entry.\(rowID)"
        ]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("trusted.example.com:22"))
        XCTAssertTrue(row.label.contains("Last used"))
        XCTAssertTrue(row.label.contains("2020"))
        XCTAssertFalse(row.label.contains("SHA256"))
        XCTAssertFalse(
            app.buttons["vvterm.settings.trustedHosts.actions.\(rowID)"].exists
        )
    }

    @MainActor
    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-trusted-hosts-settings-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }
}
#endif
