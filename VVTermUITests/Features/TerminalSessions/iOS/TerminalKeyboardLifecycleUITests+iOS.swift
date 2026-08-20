#if os(iOS)
import XCTest

final class TerminalKeyboardLifecycleUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testBackgroundRoundTripPreservesTerminalTyping() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(
            for: diagnostics,
            labelContaining: "keyboardVisible=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let baselineInputRebuilds = try requiredDiagnosticMetric("inputRebuilds", in: app)
        let baselineGridResizes = try requiredDiagnosticMetric("gridResizes", in: app)

        for _ in 0..<3 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(
                waitForBackgroundState(of: app, timeout: 8),
                "VVTerm did not enter the background. \(diagnosticsText(in: app))"
            )

            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 8),
                "VVTerm did not return to the foreground. \(diagnosticsText(in: app))"
            )

            wait(
                for: diagnostics,
                labelContaining: "renderingPaused=false",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
        }

        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertEqual(
            try requiredDiagnosticMetric("inputRebuilds", in: app),
            baselineInputRebuilds,
            "Backgrounding rebuilt the terminal input session. \(diagnosticsText(in: app))"
        )
        XCTAssertEqual(
            try requiredDiagnosticMetric("gridResizes", in: app),
            baselineGridResizes,
            "App switching sent a transient PTY resize while terminal rendering was paused. \(diagnosticsText(in: app))"
        )

        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testKeyboardHarnessMenuRepairsUnexpectedKeyboardLoss() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        let transitionBaseline = try induceUnexpectedKeyboardLoss(in: app)
        repairUnexpectedKeyboardLossFromMenu(since: transitionBaseline, in: app)

        let key = app.keys["x"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testOpenMenuStaysVisibleDuringTerminalTitleAndWorkingDirectoryUpdates() throws {
        let app = launchKeyboardHarness(simulatesTerminalMetadataChurn: true)
        let menu = app.buttons["vvterm.keyboardTest.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), diagnosticsText(in: app))

        menu.tap()

        let settingsItem = app.descendants(matching: .any)["vvterm.keyboardTest.menu.settings"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), diagnosticsText(in: app))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        XCTAssertTrue(
            settingsItem.exists && settingsItem.isHittable,
            "Open menu closed or blinked during terminal metadata updates. \(diagnosticsText(in: app))"
        )
    }

    @MainActor
    func testKeyboardMenuDismissesFindAndTransfersInputToTerminal() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let menu = app.buttons["vvterm.keyboardTest.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), diagnosticsText(in: app))
        menu.tap()

        let findItem = app.descendants(matching: .any)["vvterm.keyboardTest.menu.find"]
        XCTAssertTrue(findItem.waitForExistence(timeout: 5), diagnosticsText(in: app))
        findItem.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 8),
            "Native Find search field did not appear. \(diagnosticsText(in: app))"
        )
        searchField.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "find=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "findPresented=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticsText(in: app))
        searchField.typeText("focus")
        XCTAssertEqual(searchField.value as? String, "focus", diagnosticsText(in: app))

        requestKeyboardFromMenu(in: app)

        wait(for: diagnostics, labelContaining: "find=false", timeout: 8, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "findPresented=false", timeout: 8, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 8, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryVisible(in: app)

        let key = app.keys["x"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testCodexPromptKeyboardLossIsRepairedAndReturnsInputToTerminal() throws {
        let app = launchKeyboardHarness(simulatesCodexTUIResponse: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        let transitionBaseline = try keyboardTransitionBaseline(in: app)

        terminal.typeText("hello")
        assertKeyboardAndAccessoryVisible(in: app)
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        let returnKey = app.buttons["Return"]
        XCTAssertTrue(returnKey.waitForExistence(timeout: 5), diagnosticsText(in: app))
        returnKey.tap()
        wait(for: diagnostics, labelContaining: "returnInputs=1", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "codexResponses=1", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryVisible(in: app)
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardStateStable(since: transitionBaseline, in: app)

        let repairBaseline = try induceUnexpectedKeyboardLoss(in: app)
        repairUnexpectedKeyboardLossFromMenu(since: repairBaseline, in: app)

        let key = app.keys["x"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testPrivacyModeBackgroundResumeRestoresResponsiveTerminal() throws {
        let app = launchKeyboardHarness(privacyModeEnabled: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForBackgroundState(of: app, timeout: 8),
            "VVTerm did not enter the background. \(diagnosticsText(in: app))"
        )

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 8),
            "VVTerm did not return to the foreground. \(diagnosticsText(in: app))"
        )

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        let key = app.keys["p"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=70",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testPrivacyShieldHidesAccessoryAndRestoresResponsiveTerminal() throws {
        let app = launchKeyboardHarness(privacyModeEnabled: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.privacy.shield"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboardTest.privacyShield"]
                .waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.privacy.resume"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboardTest.privacyShield"]
                .waitForNonExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        wait(
            for: app.staticTexts["vvterm.keyboardTest.diagnostics"],
            labelContaining: "renderingPaused=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let key = app.keys["s"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticsText(in: app))
        key.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=73",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testTemporarySystemOverlayDetachesAndRestoresAccessoryWithoutLosingTyping() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.scene.inactive"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=inactive",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.scene.active"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.geometry.floating"].tap()
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testTemporarySystemOverlayPreservesUserHiddenKeyboardIntent() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(
            for: diagnostics,
            labelContaining: "keyboardVisible=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.scene.inactive"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=inactive",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryRemainHidden(in: app)

        app.buttons["vvterm.keyboardTest.scene.active"].tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=connected",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryRemainHidden(in: app)
    }

    @MainActor
    func testCrossAppFocusTransferReleasesResponderWithoutRebuild() throws {
        let app = launchKeyboardHarness(
            preservesTerminalSize: true,
            simulatesKeyboardFrames: true
        )
        let terminal = waitForTerminal(in: app)
        terminal.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let dockedButton = app.buttons["vvterm.keyboardTest.geometry.docked"]
        XCTAssertTrue(dockedButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        dockedButton.tap()
        wait(
            for: diagnostics,
            labelContaining: "sizePreserved=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let transferButton = app.buttons["vvterm.keyboardTest.window.notKey"]
        XCTAssertTrue(transferButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        transferButton.tap()
        wait(
            for: diagnostics,
            labelContaining: "reconnect=inactive",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "sizePreserved=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let rebuildCount = try requiredDiagnosticMetric("inputRebuilds", in: app)

        let returnButton = app.buttons["vvterm.keyboardTest.window.key"]
        XCTAssertTrue(returnButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        returnButton.tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.geometry.floating"].tap()
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertEqual(
            try requiredDiagnosticMetric("inputRebuilds", in: app),
            rebuildCount,
            diagnosticsText(in: app)
        )

        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testSameScreenForeignKeyboardDoesNotReclaimTerminalAccessory() {
        let app = launchKeyboardHarness(
            preservesTerminalSize: true,
            simulatesKeyboardFrames: true
        )
        let terminal = waitForTerminal(in: app)
        terminal.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(
            for: diagnostics,
            labelContaining: "keyboardPresentation=docked",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.geometry.foreignDocked"].tap()
        wait(
            for: diagnostics,
            labelContaining: "foreignKeyboardFrames=1",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessorySuppressed=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.window.key"].tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testRepeatedTerminalReconstructionKeepsRenderingAndInputResponsive() throws {
        let app = launchKeyboardHarness()
        var terminal = waitForTerminal(in: app)
        terminal.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        for _ in 0..<12 {
            app.buttons["vvterm.keyboardTest.mode.other"].tap()
            XCTAssertTrue(
                app.buttons["vvterm.keyboardTest.nonTerminalSurface"].waitForExistence(timeout: 3),
                diagnosticsText(in: app)
            )

            app.buttons["vvterm.keyboardTest.mode.terminal"].tap()
            terminal = waitForTerminal(in: app)
        }

        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

}
#endif

