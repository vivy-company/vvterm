#if os(macOS)
import XCTest

final class SettingsPrivacyProtectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrivacyModeKeepsActiveSettingsInteractive() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.privacyModeEnabled", "YES",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        let settingsSearch = app.searchFields["Search Settings"]
        XCTAssertTrue(settingsSearch.waitForExistence(timeout: 10))
        XCTAssertTrue(settingsSearch.isHittable)
        settingsSearch.click()
        settingsSearch.typeText("terminal")
        XCTAssertEqual(settingsSearch.value as? String, "terminal")
    }
}
#endif
