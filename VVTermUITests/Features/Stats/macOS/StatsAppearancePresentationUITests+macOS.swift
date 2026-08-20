#if os(macOS)
import XCTest

final class StatsAppearancePresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStatsAppearanceCanBeClosedFromNavigationSettings() throws {
        let app = XCUIApplication()
        app.launch()

        app.typeKey(",", modifierFlags: .command)

        let navigationAndStats = app.staticTexts["Server Views"]
        XCTAssertTrue(navigationAndStats.waitForExistence(timeout: 5))
        navigationAndStats.click()

        let statsAppearance = app.buttons["vvterm.settings.navigationAndStats.statsAppearance"]
        XCTAssertTrue(statsAppearance.waitForExistence(timeout: 5))
        statsAppearance.click()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

        XCTAssertTrue(statsAppearance.waitForExistence(timeout: 5))
    }
}
#endif
