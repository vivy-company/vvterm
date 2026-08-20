#if os(iOS)
import XCTest

final class TerminalKeyboardOwnershipUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testRepeatedSplitPaneFocusKeepsOneInputUISessionWithoutReloadLoop() throws {
        let app = launchKeyboardHarness(splitPaneFocus: true)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let firstTerminal = app.descendants(matching: .any)[
            "vvterm.keyboardTest.terminalSurface.first"
        ]
        let secondTerminal = app.descendants(matching: .any)[
            "vvterm.keyboardTest.terminalSurface.second"
        ]
        XCTAssertTrue(firstTerminal.waitForExistence(timeout: 10), diagnosticsText(in: app))
        XCTAssertTrue(secondTerminal.waitForExistence(timeout: 10), diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.focus.first"].tap()
        firstTerminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            diagnosticsText(in: app)
        )
        let baselineReloads = try diagnosticMetric("totalInputReloads", in: app)
        let baselineRebuilds = try diagnosticMetric("totalInputRebuilds", in: app)

        for index in 0..<20 {
            let focusesSecond = index.isMultiple(of: 2)
            app.buttons[
                focusesSecond
                    ? "vvterm.keyboardTest.focus.second"
                    : "vvterm.keyboardTest.focus.first"
            ].tap()
            wait(
                for: diagnostics,
                labelContaining: focusesSecond
                    ? "focusedPane=second"
                    : "focusedPane=first",
                timeout: 3,
                diagnostics: diagnosticsText(in: app)
            )
            wait(
                for: diagnostics,
                labelContaining: "softwareInputActive=true",
                timeout: 3,
                diagnostics: diagnosticsText(in: app)
            )
        }

        let finalReloads = try diagnosticMetric("totalInputReloads", in: app)
        let finalRebuilds = try diagnosticMetric("totalInputRebuilds", in: app)
        XCTAssertLessThanOrEqual(finalReloads, baselineReloads + 1, diagnosticsText(in: app))
        XCTAssertEqual(finalRebuilds, baselineRebuilds, diagnosticsText(in: app))
        XCTAssertTrue(app.keyboards.firstMatch.exists, diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardware=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
            diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "coordinatorKeyboardVisible=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        waitForDiagnosticMetrics(in: app) { metrics in
            guard let gap = metrics["layoutBottomGap"] else { return false }
            return gap < 100
        }

        let commands: [(button: String, action: String)] = [
            ("vvterm.keyboardTest.command.cmdD", "splitRight"),
            ("vvterm.keyboardTest.command.cmdAltLeft", "selectLeft"),
            ("vvterm.keyboardTest.command.cmdCtrlRight", "moveDividerRight"),
        ]
        for (index, command) in commands.enumerated() {
            app.buttons[command.button].tap()
            wait(
                for: diagnostics,
                labelContaining: "paneShortcutActions=\(index + 1)",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            wait(
                for: diagnostics,
                labelContaining: "lastPaneShortcutAction=\(command.action)",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
        }
    }

    @MainActor
    func testKeyboardButtonRestoresAfterUserHideButTerminalTapDoesNot() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        terminal.tap()
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        // A stale GCKeyboard attachment observation must not veto an explicit
        // accessory dismissal. The dismiss action itself proves that software
        // keyboard recovery controls are required.
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 3, diagnostics: diagnosticsText(in: app))

        let harnessHideButton = app.buttons["vvterm.keyboardTest.hideViaToolbar"]
        XCTAssertTrue(
            harnessHideButton.waitForExistence(timeout: 5),
            """
            Harness hide control did not mount.
            \(diagnosticsText(in: app))
            """
        )

        // The simulator may suppress its real software keyboard when a Mac
        // keyboard is connected. This invokes the same production accessory
        // action while keyboard geometry remains deterministic.
        harnessHideButton.tap()
        wait(for: diagnostics, labelContaining: "hideRequests=1", timeout: 3, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "userHidden=true", timeout: 3, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        let floatingKeyboardButton = app.buttons["vvterm.terminal.floating.keyboard"]
        let floatingVoiceButton = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(
            floatingKeyboardButton.waitForExistence(timeout: 2),
            "Keyboard recovery control did not replace the dismissed accessory. \(diagnosticsText(in: app))"
        )
        XCTAssertTrue(
            floatingVoiceButton.waitForExistence(timeout: 2),
            "Voice input recovery control did not replace the dismissed accessory. \(diagnosticsText(in: app))"
        )

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackgroundState(of: app, timeout: 8), diagnosticsText(in: app))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8), diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "userHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "coordinatorKeyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
            "The software keyboard returned while dismissed. \(diagnosticsText(in: app))"
        )
        XCTAssertTrue(floatingKeyboardButton.exists, diagnosticsText(in: app))
        XCTAssertTrue(floatingVoiceButton.exists, diagnosticsText(in: app))

        // UIKit can deliver another accessory dismissal after our model has
        // already recorded the hidden state. The explicit action must still
        // republish that state so both recovery controls remain rendered.
        harnessHideButton.tap()
        wait(for: diagnostics, labelContaining: "hideRequests=2", timeout: 3, diagnostics: diagnosticsText(in: app))
        XCTAssertTrue(
            floatingKeyboardButton.waitForExistence(timeout: 2),
            "Keyboard recovery control disappeared after a repeated dismiss. \(diagnosticsText(in: app))"
        )
        XCTAssertTrue(
            floatingVoiceButton.waitForExistence(timeout: 2),
            "Voice input recovery control disappeared after a repeated dismiss. \(diagnosticsText(in: app))"
        )

        floatingVoiceButton.tap()
        XCTAssertTrue(
            floatingVoiceButton.waitForNonExistence(timeout: 2),
            "Voice control stayed visible while recording. \(diagnosticsText(in: app))"
        )

        app.buttons["vvterm.keyboardTest.voice.transcriptionSent"].tap()
        let floatingReturnButton = app.buttons["vvterm.terminal.floating.return"]
        XCTAssertTrue(
            floatingReturnButton.waitForExistence(timeout: 2),
            "Return control did not appear after transcription. \(diagnosticsText(in: app))"
        )
        floatingReturnButton.tap()
        XCTAssertTrue(
            floatingReturnButton.waitForNonExistence(timeout: 2),
            "Return control did not clear after use. \(diagnosticsText(in: app))"
        )

        terminal.tap()
        wait(for: diagnostics, labelContaining: "userHidden=true", timeout: 3, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        let transitionBaseline = try keyboardTransitionBaseline(in: app)
        app.buttons["vvterm.keyboardTest.hardware.detach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 3, diagnostics: diagnosticsText(in: app))
        floatingKeyboardButton.tap()
        wait(for: diagnostics, labelContaining: "userHidden=false", timeout: 3, diagnostics: diagnosticsText(in: app))
        XCTAssertFalse(floatingKeyboardButton.exists)
        XCTAssertFalse(floatingVoiceButton.exists)
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertSingleKeyboardRestore(since: transitionBaseline, in: app)
    }

    @MainActor
    func testKeyboardIsScopedToTerminalSurface() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.mode.other"].tap()
        XCTAssertTrue(
            app.buttons["vvterm.keyboardTest.nonTerminalSurface"].waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.mode.terminal"].tap()
        _ = waitForTerminal(in: app)
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testSettingsSheetReleasesAndRestoresTerminalKeyboardOwnership() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        terminal.tap()
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        let settingsSheet = openSettingsSheet(in: app)
        wait(
            for: diagnostics,
            labelContaining: "softwareInputActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        closeSettingsSheet(settingsSheet, in: app)
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        terminal.typeText("x")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=78",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        let hiddenIntentSettingsSheet = openSettingsSheet(in: app)
        wait(for: diagnostics, labelContaining: "softwareInputActive=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        closeSettingsSheet(hiddenIntentSettingsSheet, in: app)

        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryRemainHidden(in: app)
    }

    @MainActor
    func testSettingsSheetDoesNotOverlapRealSoftwareKeyboard() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        guard app.keyboards.firstMatch.waitForExistence(timeout: 8),
              waitForLabel(diagnostics, containing: "keyboardVisible=true", timeout: 8),
              waitForLabel(diagnostics, containing: "accessoryAttached=true", timeout: 5) else {
            throw XCTSkip(
                "Simulator suppressed the baseline software keyboard. \(diagnosticsText(in: app))"
            )
        }
        assertKeyboardAndAccessoryVisible(in: app)

        let settingsSheet = openSettingsSheet(in: app)
        assertKeyboardAndAccessoryHidden(in: app)
        wait(for: diagnostics, labelContaining: "softwareInputActive=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        closeSettingsSheet(settingsSheet, in: app)
        assertKeyboardAndAccessoryVisible(in: app)
    }

}
#endif
