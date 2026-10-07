#if os(iOS)
import XCTest
import UIKit

final class TerminalSettingsNavigationUITests: TerminalReconnectUITestCase {
    @MainActor
    func testNormalModeMenuIgnoresUnchangedKeyboardState() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(repeatsKeyboardStateUpdates: true)
        defer { app.terminate() }
        _ = productionTerminal(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        openProductionTerminalMenu(in: app)
        let settings = app.buttons["vvterm.terminal.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let frame = settings.frame
        let baseline = try terminalSnapshot(in: diagnostics, app: app)
        let updates = try XCTUnwrap(diagnosticIntegerValue("routeUpdates", in: diagnostics))
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(settings.exists && settings.isHittable)
            XCTAssertEqual(settings.frame, frame)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertEqual(diagnosticIntegerValue("routeUpdates", in: diagnostics), updates)
        }
        assertSameSession(as: baseline, diagnostics: diagnostics, app: app)
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["vvterm.settings.root"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNormalModeMenuStaysStableWithKeyboardOptions() throws {
        try assertProductionInitialKeyboardAndMenu(preserves: false, keyboardOptions: 63, repeatsKeyboardUpdates: true)
    }

    @MainActor
    func testNormalModeHonorsAutoCapitalization() {
        let (app, _) = launchProductionSSHTestHarness(keyboardOptions: 2)
        defer { app.terminate() }
        _ = productionTerminal(in: app)
        XCTAssertFalse(app.textViews["vvterm.composer.text"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        for letter in ["h", "e", "l", "l", "o"] { app.keyboards.keys[letter].tap() }
        app.keyboards.keys["more"].tap()
        app.keyboards.keys["."].tap()
        app.keyboards.keys["space"].tap()
        XCTAssertTrue(app.keyboards.keys["A"].waitForExistence(timeout: 5))
        app.keyboards.keys["A"].tap()
        XCTAssertTrue(app.keyboards.keys["a"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPrivacyControlCenterPreservesChatInput() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(privacyModeEnabled: true, chatMode: true)
        defer { app.terminate() }
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("before")
        let frame = editor.frame
        let baseline = try terminalSnapshot(in: diagnostics, app: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.65)))
            XCTAssertTrue(springboard.otherElements["cc-root-folder-view"].waitForExistence(timeout: 5))
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.frame.minY, frame.minY, accuracy: 1)
            XCTAssertEqual(editor.value as? String, "before")
            assertSameSession(as: baseline, diagnostics: diagnostics, app: app)
        }
        editor.typeText(" after")
        XCTAssertEqual(editor.value as? String, "before after")
    }

    @MainActor
    func testProductionInitialKeyboardAndMenuWithPreservationOff() throws {
        try assertProductionInitialKeyboardAndMenu(preserves: false)
    }

    @MainActor
    func testProductionInitialKeyboardAndMenuWithPreservationOn() throws {
        try assertProductionInitialKeyboardAndMenu(preserves: true)
    }

    @MainActor
    func testProductionInitialKeyboardAndMenuWithPrivacyMode() throws {
        try assertProductionInitialKeyboardAndMenu(preserves: false, privacyModeEnabled: true)
    }

    @MainActor
    private func assertProductionInitialKeyboardAndMenu(
        preserves: Bool, privacyModeEnabled: Bool = false, keyboardOptions: Int = 0, repeatsKeyboardUpdates: Bool = false
    ) throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(
            preservesTerminalSize: preserves, privacyModeEnabled: privacyModeEnabled, keyboardOptions: keyboardOptions,
            repeatsKeyboardUpdates: repeatsKeyboardUpdates
        )
        defer { app.terminate() }
        _ = productionTerminal(in: app)
        // No tap or explicit Keyboard action may repair the initial state.
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 8, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))
        XCTAssertTrue(app.keyboards.keys["a"].isHittable, diagnosticText(in: app))
        let baseline = try terminalSnapshot(in: diagnostics, app: app)
        let reloads = diagnosticIntegerValue("inputReloads", in: diagnostics)
        openProductionTerminalMenu(in: app)
        let settings = app.buttons["vvterm.terminal.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), diagnosticText(in: app))
        let menuFrame = settings.frame
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(settings.exists && settings.isHittable, diagnosticText(in: app))
            XCTAssertTrue(app.keyboards.firstMatch.exists, diagnosticText(in: app))
            XCTAssertEqual(settings.frame, menuFrame)
            XCTAssertEqual(diagnosticIntegerValue("inputReloads", in: diagnostics), reloads)
        }
        assertSameSession(as: baseline, diagnostics: diagnostics, app: app)
    }

    @MainActor
    func testProductionSettingsReleasesDockedInputWithPreservationOn() throws {
        try assertProductionSettingsInput(preserves: true, floating: false)
    }

    @MainActor
    func testProductionSettingsReleasesDockedInputWithPreservationOff() throws {
        try assertProductionSettingsInput(preserves: false, floating: false)
    }

    @MainActor
    func testProductionSettingsReleasesFloatingInputWithPreservationOn() throws {
        try assertProductionSettingsInput(preserves: true, floating: true)
    }

    @MainActor
    func testProductionSettingsReleasesFloatingInputWithPreservationOff() throws {
        try assertProductionSettingsInput(preserves: false, floating: true)
    }

    @MainActor
    private func assertProductionSettingsInput(preserves: Bool, floating: Bool) throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(preservesTerminalSize: preserves)
        defer { app.terminate() }
        let terminal = productionTerminal(in: app)
        terminal.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 8) else {
            throw XCTSkip("Simulator suppressed the software keyboard. \(diagnosticText(in: app))")
        }
        if floating {
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                throw XCTSkip("Floating keyboard needs iPadOS.")
            }
            keyboard.pinch(withScale: 0.35, velocity: -2)
            let floatingFrame = NSPredicate { _, _ in
                keyboard.exists && keyboard.frame.width < app.frame.width * 0.5
            }
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: floatingFrame, object: nil)], timeout: 5) == .completed else {
                throw XCTSkip("The native floating keyboard gesture was unavailable.")
            }
        }
        var preservedPTYTitle: String?
        if preserves {
            let rows = try XCTUnwrap(diagnosticIntegerValue("gridRows", in: diagnostics))
            let columns = try XCTUnwrap(diagnosticIntegerValue("gridCols", in: diagnostics))
            // The real SSH PTY reports its size and counts every window-change
            // signal, including transient resizes that later return to baseline.
            let command = #"report_size() { set -- $(stty size); printf '\033]0;PTY_%s_%s_%s\007' "$1" "$2" "$resize_count"; }; resize_count=0; trap 'resize_count=$((resize_count+1)); report_size' WINCH; report_size"#
            terminal.typeText(command + "\n")
            let title = "title=PTY_\(rows)_\(columns)_0"
            wait(for: diagnostics, containing: title, timeout: 8, app: app)
            preservedPTYTitle = title
        }
        for _ in 0..<3 {
            openProductionTerminalMenu(in: app)
            app.buttons["vvterm.terminal.settings"].tap()
            let settings = app.descendants(matching: .any)["vvterm.settings.root"]
            XCTAssertTrue(settings.waitForExistence(timeout: 8), diagnosticText(in: app))
            wait(for: diagnostics, containing: "imeProxyFirstResponder=false", timeout: 5, app: app)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), diagnosticText(in: app))
            wait(for: diagnostics, containing: "accessoryAttached=false", timeout: 5, app: app)

            let search = app.searchFields["Search Settings"]
            if !search.waitForExistence(timeout: 2) { settings.swipeDown() }
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("terminal")
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            wait(for: diagnostics, containing: "imeProxyFirstResponder=false", timeout: 5, app: app)
            XCTAssertEqual(search.value as? String, "terminal")
            app.buttons["vvterm.settings.close"].tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
            wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 5, app: app)
            if let preservedPTYTitle {
                wait(for: diagnostics, containing: preservedPTYTitle, timeout: 5, app: app)
            }
        }
    }

    @MainActor
    func testServerListCanOpenSettingsFromItsToolbar() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.root"]
                .waitForExistence(timeout: 8),
            "Settings did not open from the server list toolbar."
        )
    }

    @MainActor
    func testGroupedSettingsOpenGeneralAndTerminalPages() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let navigationRoute = app.buttons["vvterm.settings.route.navigationAndStats"]
        XCTAssertTrue(navigationRoute.waitForExistence(timeout: 8))
        navigationRoute.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.navigationAndStats"]
                .waitForExistence(timeout: 8),
            "The Server Views page did not open."
        )
        XCTAssertTrue(
            app.buttons["vvterm.settings.navigationAndStats.statsAppearance"].exists
        )

        let settingsBackButton = app.navigationBars["Server Views"].buttons["Settings"]
        XCTAssertTrue(settingsBackButton.waitForExistence(timeout: 5))
        settingsBackButton.tap()

        let searchField = app.searchFields["Search Settings"]
        if !searchField.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("tmux")

        let sessionsRoute = app.buttons["vvterm.settings.route.sessionsAndConnections"]
        XCTAssertTrue(sessionsRoute.waitForExistence(timeout: 5))
        sessionsRoute.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.sessionsAndConnections"]
                .waitForExistence(timeout: 8),
            "The Sessions & SSH page did not open."
        )
        XCTAssertTrue(app.switches["Enable tmux by default"].exists)
        XCTAssertTrue(app.switches["Keep screen awake"].exists)
    }

    @MainActor
    func testVoiceInputSettingsUseGroupedLayoutBelowNavigationBar() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
            "-transcriptionProvider", "mlxWhisper",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let voiceInputRoute = app.buttons["vvterm.settings.route.transcription"]
        XCTAssertTrue(voiceInputRoute.waitForExistence(timeout: 8))
        voiceInputRoute.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.transcription"]
                .waitForExistence(timeout: 8)
        )

        let navigationBar = app.navigationBars["Voice Input"]
        let accessHeader = app.staticTexts["Access"]
        XCTAssertTrue(navigationBar.exists)
        XCTAssertTrue(accessHeader.exists)
        XCTAssertGreaterThanOrEqual(
            accessHeader.frame.minY,
            navigationBar.frame.maxY,
            "The first section heading must not be clipped by the navigation bar."
        )
        XCTAssertTrue(app.switches["Show in Terminal"].exists)
        XCTAssertTrue(app.staticTexts["Transcription"].exists)
    }

    @MainActor
    func testAppearanceAndCursorChoicesAreSelectedButtons() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let appearanceRoute = app.buttons["vvterm.settings.route.appearanceAndLanguage"]
        XCTAssertTrue(appearanceRoute.waitForExistence(timeout: 8))
        appearanceRoute.tap()

        let systemAppearance = app.buttons["vvterm.settings.appearance.system"]
        let lightAppearance = app.buttons["vvterm.settings.appearance.light"]
        let darkAppearance = app.buttons["vvterm.settings.appearance.dark"]
        XCTAssertTrue(systemAppearance.waitForExistence(timeout: 5))
        XCTAssertEqual([systemAppearance, lightAppearance, darkAppearance].filter(\.isSelected).count, 1)
        let appearanceTarget = darkAppearance.isSelected ? lightAppearance : darkAppearance
        appearanceTarget.tap()
        XCTAssertTrue(appearanceTarget.isSelected)

        app.navigationBars["Appearance & Language"].buttons["Settings"].tap()

        let terminalAppearanceRoute = app.buttons["vvterm.settings.route.terminalAppearance"]
        XCTAssertTrue(terminalAppearanceRoute.waitForExistence(timeout: 5))
        terminalAppearanceRoute.tap()

        let blockCursor = app.buttons["vvterm.settings.cursor.block"]
        let barCursor = app.buttons["vvterm.settings.cursor.bar"]
        XCTAssertTrue(blockCursor.waitForExistence(timeout: 5))
        let underlineCursor = app.buttons["vvterm.settings.cursor.underline"]
        let hollowCursor = app.buttons["vvterm.settings.cursor.block_hollow"]
        let cursorButtons = [blockCursor, barCursor, underlineCursor, hollowCursor]
        XCTAssertTrue(hollowCursor.waitForExistence(timeout: 5))
        XCTAssertEqual(cursorButtons.filter(\.isSelected).count, 1)
        XCTAssertTrue(
            cursorButtons.allSatisfy { abs($0.frame.midY - blockCursor.frame.midY) < 2 },
            "All four cursor types must remain in one row."
        )
        let cursorTarget = barCursor.isSelected ? blockCursor : barCursor
        cursorTarget.tap()
        XCTAssertTrue(cursorTarget.isSelected)

        let customThemes = app.buttons["vvterm.settings.appearance.customThemes"]
        if !customThemes.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(customThemes.waitForExistence(timeout: 5))
        customThemes.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.customThemes.page"]
                .waitForExistence(timeout: 5)
        )
        let customThemesBack = app.navigationBars["Custom Themes"].buttons.firstMatch
        XCTAssertTrue(customThemesBack.exists)
        customThemesBack.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.terminalAppearance"]
                .waitForExistence(timeout: 5),
            "Closing Custom Themes must return to Terminal Appearance."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.root"].exists,
            "Closing Custom Themes must not dismiss Settings."
        )
    }

    @MainActor
    func testRemoteClipboardShowsOneWarning() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-terminalRemoteClipboardReadPolicy", "allow",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let clipboardRoute = app.buttons["vvterm.settings.route.clipboardAndPaste"]
        XCTAssertTrue(clipboardRoute.waitForExistence(timeout: 8))
        clipboardRoute.tap()

        XCTAssertTrue(
            app.staticTexts["Warning: Remote programs can read or change your clipboard without asking."]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.staticTexts["Remote programs can read clipboard data without asking."].exists
        )
    }

    @MainActor
    func testKeyboardInputUsesFocusedSections() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let keyboardRoute = app.buttons["vvterm.settings.route.keyboardAndInput"]
        if !keyboardRoute.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(keyboardRoute.waitForExistence(timeout: 5))
        keyboardRoute.tap()

        XCTAssertTrue(app.staticTexts["Hardware Keyboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Software Keyboard"].exists)
        XCTAssertTrue(app.staticTexts["Accessory Bar"].exists)
        XCTAssertTrue(app.switches["Keep terminal size"].exists)
        XCTAssertTrue(app.switches["Show dismiss button"].exists)
        XCTAssertTrue(app.buttons["Customize Accessory Bar"].exists)
        XCTAssertTrue(app.buttons["Custom Actions"].exists)
        XCTAssertFalse(app.switches["Keep terminal size when keyboard opens"].exists)
        XCTAssertFalse(app.switches["Show keyboard dismiss button"].exists)
        app.buttons["vvterm.settings.inputMode"].tap()
        XCTAssertTrue(app.segmentedControls["vvterm.input-mode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["vvterm.settings.inputMode.preview"].exists)
    }

    @MainActor
    func testProSettingsUsesOneStatusHero() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let proRoute = app.buttons["vvterm.settings.route.pro"]
        XCTAssertTrue(proRoute.waitForExistence(timeout: 5))
        proRoute.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.page.pro"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.pro.statusHero"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Restore Purchases"].exists)
        XCTAssertFalse(app.staticTexts["Subscription"].exists)
        XCTAssertFalse(app.staticTexts["Purchased"].exists)
    }

    @MainActor
    func testConnectedTerminalCanOpenSettingsFromItsToolbar() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES",
            "-terminalTmuxEnabledDefault", "NO",
            "-terminalUsePerAppearanceTheme", "NO",
            "-terminalThemeName", "Aizen Dark",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 45,
            app: app
        )

        XCTAssertFalse(app.navigationBars.staticTexts["DEV-199 Loopback"].exists,
                       "Connection screens must keep the server name out of the toolbar title.")

        openProductionTerminalMenu(in: app)
        let settings = app.buttons["vvterm.terminal.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), diagnosticText(in: app))
        settings.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.settings.root"]
                .waitForExistence(timeout: 8),
            "Settings did not open from the connected terminal toolbar. \(diagnosticText(in: app))"
        )
    }

}
#endif
