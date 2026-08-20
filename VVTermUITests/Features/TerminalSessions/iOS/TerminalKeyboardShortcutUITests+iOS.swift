#if os(iOS)
import XCTest

final class TerminalKeyboardShortcutUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testIMEProxyMarkedTextDeleteAndCommitPath() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        app.buttons["vvterm.keyboardTest.ime.mark"].tap()
        wait(for: diagnostics, labelContaining: "imeComposing=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeMarkedText=nihon", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeModelText=nihon", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.ime.delete"].tap()
        wait(for: diagnostics, labelContaining: "imeComposing=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeMarkedText=niho", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeModelText=niho", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.ime.commit"].tap()
        wait(for: diagnostics, labelContaining: "imeComposing=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeMarkedText=empty", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeModelText=niho", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testCommandPlusAndMinusZoomWithoutReachingTerminalInput() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        terminal.tap()
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("=", modifierFlags: .command)
        wait(for: diagnostics, labelContaining: "zoomActions=1", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastZoomAction=zoomIn", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("=", modifierFlags: [.command, .shift])
        wait(for: diagnostics, labelContaining: "zoomActions=2", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastZoomAction=zoomIn", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("-", modifierFlags: .command)
        wait(for: diagnostics, labelContaining: "zoomActions=3", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastZoomAction=zoomOut", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("0", modifierFlags: .command)
        wait(for: diagnostics, labelContaining: "zoomActions=4", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastZoomAction=reset", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("=", modifierFlags: [])
        wait(for: diagnostics, labelContaining: "inputHex=3d", timeout: 5, diagnostics: diagnosticsText(in: app))
        app.typeKey("-", modifierFlags: [])
        wait(for: diagnostics, labelContaining: "inputHex=2d", timeout: 5, diagnostics: diagnosticsText(in: app))
        app.typeKey("0", modifierFlags: [])
        wait(for: diagnostics, labelContaining: "inputHex=30", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "zoomActions=4", timeout: 5, diagnostics: diagnosticsText(in: app))
    }

    @MainActor
    func testSplitPaneShortcutsRouteWithoutReachingTerminalInput() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        terminal.tap()
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("d", modifierFlags: .command)
        wait(for: diagnostics, labelContaining: "paneShortcutActions=1", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastPaneShortcutAction=splitRight", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.typeKey("d", modifierFlags: [.command, .shift])
        wait(for: diagnostics, labelContaining: "paneShortcutActions=2", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastPaneShortcutAction=splitDown", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))

        let commands: [(key: String, modifiers: XCUIElement.KeyModifierFlags, action: String)] = [
            (XCUIKeyboardKey.upArrow.rawValue, [.command, .option], "selectAbove"),
            (XCUIKeyboardKey.downArrow.rawValue, [.command, .option], "selectBelow"),
            (XCUIKeyboardKey.leftArrow.rawValue, [.command, .option], "selectLeft"),
            (XCUIKeyboardKey.rightArrow.rawValue, [.command, .option], "selectRight"),
            (XCUIKeyboardKey.upArrow.rawValue, [.command, .control], "moveDividerUp"),
            (XCUIKeyboardKey.downArrow.rawValue, [.command, .control], "moveDividerDown"),
            (XCUIKeyboardKey.leftArrow.rawValue, [.command, .control], "moveDividerLeft"),
            (XCUIKeyboardKey.rightArrow.rawValue, [.command, .control], "moveDividerRight"),
            ("[", [.command], "selectPrevious"),
            ("]", [.command], "selectNext"),
            ("=", [.command, .control], "equalize"),
        ]

        for (index, command) in commands.enumerated() {
            app.typeKey(command.key, modifierFlags: command.modifiers)
            wait(
                for: diagnostics,
                labelContaining: "paneShortcutActions=\(index + 3)",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            wait(
                for: diagnostics,
                labelContaining: "lastPaneShortcutAction=\(command.action)",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))
        }

        app.typeKey("w", modifierFlags: .command)
        wait(for: diagnostics, labelContaining: "paneShortcutActions=14", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "lastPaneShortcutAction=closeFocusedPane", timeout: 5, diagnostics: diagnosticsText(in: app))
        let confirmation = app.alerts["Close this terminal?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Cmd-W did not request the existing focused-pane close confirmation. \(diagnosticsText(in: app))"
        )
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
        confirmation.buttons["Close"].tap()
        wait(
            for: diagnostics,
            labelContaining: "lastPaneCloseDialogAction=close",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertFalse(
            confirmation.exists,
            "Close did not dismiss the confirmation"
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Cmd-W did not reopen the focused-pane close confirmation. \(diagnosticsText(in: app))"
        )
        confirmation.buttons["Cancel"].tap()
        wait(for: diagnostics, labelContaining: "lastPaneCloseDialogAction=cancel", timeout: 5, diagnostics: diagnosticsText(in: app))
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
        wait(for: diagnostics, labelContaining: "inputHex=none", timeout: 5, diagnostics: diagnosticsText(in: app))
    }

    @MainActor
    func testSoftwareToolbarAndCustomShortcutCombinationsUseAppRouting() throws {
        let app = launchKeyboardHarness(
            simulatesKeyboardFrames: true,
            testsAppShortcutInputs: true
        )
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        let localActions: [(button: String, action: String)] = [
            ("vvterm.keyboardTest.shortcut.software.cmdD", "splitRight"),
            ("vvterm.keyboardTest.shortcut.software.cmdShiftD", "splitDown"),
            ("vvterm.keyboardTest.shortcut.toolbar.cmdAltLeft", "selectLeft"),
            ("vvterm.keyboardTest.shortcut.custom.cmdCtrlRight", "moveDividerRight"),
        ]

        for (index, localAction) in localActions.enumerated() {
            app.buttons[localAction.button].tap()
            wait(
                for: diagnostics,
                labelContaining: "paneShortcutActions=\(index + 1)",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            wait(
                for: diagnostics,
                labelContaining: "lastPaneShortcutAction=\(localAction.action)",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            wait(
                for: diagnostics,
                labelContaining: "inputHex=none",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
        }

        app.buttons["vvterm.keyboardTest.shortcut.custom.ctrlX"].tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=18",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "paneShortcutActions=4",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.shortcut.software.cmdW"].tap()
        wait(
            for: diagnostics,
            labelContaining: "paneShortcutActions=5",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "lastPaneShortcutAction=closeFocusedPane",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let confirmation = app.alerts["Close this terminal?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Software Cmd-W did not request close confirmation. \(diagnosticsText(in: app))"
        )
        confirmation.buttons["Cancel"].tap()
    }

    @MainActor
    func testPaneCloseAlertRestoresTerminalFocusAfterCancel() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let closeAlertButton = app.buttons["vvterm.keyboardTest.closeAlert"]
        let confirmation = app.alerts["Close this terminal?"]

        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        XCTAssertTrue(
            closeAlertButton.waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        closeAlertButton.tap()
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Close confirmation did not appear. \(diagnosticsText(in: app))"
        )
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        confirmation.buttons["Close"].tap()
        wait(
            for: diagnostics,
            labelContaining: "lastPaneCloseDialogAction=close",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertFalse(
            confirmation.exists,
            "Close did not dismiss the confirmation"
        )

        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        closeAlertButton.tap()
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Close confirmation did not reopen. \(diagnosticsText(in: app))"
        )

        confirmation.buttons["Cancel"].tap()
        wait(
            for: diagnostics,
            labelContaining: "lastPaneCloseDialogAction=cancel",
            timeout: 5,
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
    }

}
#endif

