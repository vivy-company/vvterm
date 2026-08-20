#if os(iOS)
import CryptoKit
import XCTest

final class StatsStorageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-stats-storage-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.otherElements["vvterm.stats.storage.details"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testBrowsingSwipeEditVisibilityAndHealthStates() throws {
        let rootHealth = app.buttons[volumeIdentifier(
            "stable|linux|root-uuid|/",
            suffix: "health"
        )]
        let shareHealth = app.buttons[volumeIdentifier(
            "stable|linux|share-uuid|/mnt/share",
            suffix: "health"
        )]
        let containerHealth = app.buttons[volumeIdentifier(
            "fallback|linux|overlay|/var/lib/docker/overlay2/example/merged|overlay",
            suffix: "health"
        )]
        XCTAssertTrue(rootHealth.waitForExistence(timeout: 5))
        XCTAssertTrue(containerHealth.exists)
        XCTAssertEqual(rootHealth.value as? String, "Visible")
        XCTAssertEqual(containerHealth.value as? String, "Hidden")

        rootHealth.swipeLeft()
        let rootSwipeVisibility = app.buttons[volumeIdentifier(
            "stable|linux|root-uuid|/",
            suffix: "swipeVisibility"
        )]
        XCTAssertTrue(rootSwipeVisibility.waitForExistence(timeout: 3))
        rootSwipeVisibility.tap()
        XCTAssertEqual(rootHealth.value as? String, "Hidden")

        rootHealth.swipeLeft()
        XCTAssertTrue(rootSwipeVisibility.waitForExistence(timeout: 3))
        rootSwipeVisibility.tap()
        XCTAssertEqual(rootHealth.value as? String, "Visible")

        let editButton = app.buttons["vvterm.stats.storage.editMode"]
        XCTAssertTrue(editButton.exists)
        XCTAssertEqual(editButton.label, "Edit")
        editButton.tap()
        XCTAssertEqual(editButton.label, "Done")

        let rootVisibility = app.switches[volumeIdentifier(
            "stable|linux|root-uuid|/",
            suffix: "visibility"
        )]
        let containerVisibility = app.switches[volumeIdentifier(
            "fallback|linux|overlay|/var/lib/docker/overlay2/example/merged|overlay",
            suffix: "visibility"
        )]
        XCTAssertTrue(rootVisibility.waitForExistence(timeout: 3))
        XCTAssertTrue(containerVisibility.exists)
        XCTAssertEqual(rootVisibility.value as? String, "Visible")
        XCTAssertEqual(containerVisibility.value as? String, "Hidden")

        let showContainers = app.buttons["vvterm.stats.storage.showContainers"]
        XCTAssertTrue(showContainers.waitForExistence(timeout: 3))
        showContainers.tap()
        XCTAssertEqual(containerVisibility.value as? String, "Visible")

        let hideContainers = app.buttons["vvterm.stats.storage.hideContainers"]
        XCTAssertTrue(hideContainers.waitForExistence(timeout: 3))
        hideContainers.tap()
        XCTAssertEqual(containerVisibility.value as? String, "Hidden")

        tapSwitchControl(rootVisibility)
        tapSwitchControl(containerVisibility)
        XCTAssertEqual(rootVisibility.value as? String, "Hidden")
        XCTAssertEqual(containerVisibility.value as? String, "Visible")

        editButton.tap()
        XCTAssertEqual(editButton.label, "Edit")
        XCTAssertEqual(rootHealth.value as? String, "Hidden")
        XCTAssertEqual(containerHealth.value as? String, "Visible")

        rootHealth.tap()
        XCTAssertTrue(app.staticTexts["Needs Attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A SMART pre-failure threshold is currently exceeded"].exists)
        app.staticTexts["Needs Attention"].tap()
        XCTAssertTrue(app.navigationBars["Health Findings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["A current pre-failure SMART attribute has reached its vendor threshold."].exists)
        app.navigationBars["Health Findings"].buttons["Storage Health"].tap()
        closePresentedHealth()

        let mirrorHealth = app.buttons[volumeIdentifier(
            "stable|linux|mirror-uuid|/mnt/mirror",
            suffix: "health"
        )]
        mirrorHealth.tap()
        XCTAssertTrue(app.staticTexts["Storage Members"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Some storage members could not be checked."].exists)
        XCTAssertTrue(app.buttons["vvterm.stats.storage.health.member.1"].exists)
        if !app.buttons["vvterm.stats.storage.health.member.2"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["vvterm.stats.storage.health.member.2"].waitForExistence(timeout: 3))
        closePresentedHealth()

        shareHealth.tap()
        XCTAssertTrue(app.staticTexts["Network Volume"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func closePresentedHealth() {
        let close = app.navigationBars["Storage Health"].buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(app.otherElements["vvterm.stats.storage.details"].waitForExistence(timeout: 3))
    }

    private func volumeIdentifier(_ identity: String, suffix: String) -> String {
        let token = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "vvterm.stats.storage.volume.\(token).\(suffix)"
    }

    private func tapSwitchControl(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
}
#endif
