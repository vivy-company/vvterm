#if os(macOS)
import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncPageShowsCompactHeroActionAndInlineDetails() {
        let app = launchHarness(syncEnabled: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitForExistence(timeout: 10))
        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.value.debugDescription.contains("Up to Date"))
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Last synced"))
                .firstMatch.exists
        )
        XCTAssertLessThan(hero.frame.height, 100)
        XCTAssertFalse(app.buttons["vvterm.settings.sync.detailsButton"].exists)
        XCTAssertFalse(app.staticTexts["iCloud Sync Details"].exists)
        XCTAssertFalse(app.buttons["Advanced"].exists)
        XCTAssertFalse(app.staticTexts["Stays on This Device"].exists)

        let syncNow = app.buttons["vvterm.settings.sync.action.primary"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sync Now")).count, 1)
        XCTAssertEqual(syncNow.descendants(matching: .image).count, 0)
        syncNow.click()

        let workspaces = app.descendants(matching: .any)[
            "vvterm.settings.sync.details.workspaces"
        ]
        XCTAssertTrue(scrollToElement(workspaces, in: app))
        let serverCredentials = app.descendants(matching: .any)[
            "vvterm.settings.sync.details.serverCredentials"
        ]
        XCTAssertTrue(scrollToElement(serverCredentials, in: app))
        let lastSuccessful = app.descendants(matching: .any)[
            "vvterm.settings.sync.details.lastSuccessful"
        ]
        XCTAssertTrue(scrollToElement(lastSuccessful, in: app))
        let copyDiagnostics = app.buttons["vvterm.settings.sync.copyDiagnostics"]
        XCTAssertTrue(scrollToElement(copyDiagnostics, in: app, requireHittable: true))
        XCTAssertTrue(copyDiagnostics.label.contains("Copy Diagnostics"))
        copyDiagnostics.click()
        XCTAssertTrue(copyDiagnostics.label.contains("Copied"))
    }

    @MainActor
    func testCredentialRemovalUsesNativeConfirmation() {
        let app = launchHarness(syncEnabled: false)
        defer { app.terminate() }

        let hero = app.descendants(matching: .any)["vvterm.settings.sync.statusHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.value.debugDescription.contains("Sync is Off"))
        XCTAssertFalse(app.staticTexts["Existing iCloud data is not deleted."].exists)
        XCTAssertFalse(app.buttons["vvterm.settings.sync.action.primary"].exists)

        XCTAssertFalse(app.buttons["vvterm.settings.sync.detailsButton"].exists)
        XCTAssertFalse(app.staticTexts["iCloud Sync Details"].exists)

        let remove = app.buttons["vvterm.settings.sync.removeCredentials"]
        XCTAssertTrue(scrollToElement(remove, in: app, requireHittable: true))
        XCTAssertTrue(remove.isEnabled)
        remove.click()

        XCTAssertTrue(app.buttons["Remove from iCloud Keychain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    @MainActor
    private func launchHarness(syncEnabled: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-sync-settings-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-iCloudSyncEnabled", syncEnabled ? "YES" : "NO",
        ]
        if !syncEnabled {
            app.launchArguments.append("--vvterm-ui-test-sync-settings-disabled")
        }
        app.launch()
        return app
    }

    @MainActor
    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        requireHittable: Bool = false
    ) -> Bool {
        func isReady() -> Bool {
            element.exists && (!requireHittable || element.isHittable)
        }

        if isReady() {
            return true
        }
        for _ in 0..<8 {
            app.swipeUp()
            if isReady() {
                return true
            }
        }
        return false
    }
}
#endif
