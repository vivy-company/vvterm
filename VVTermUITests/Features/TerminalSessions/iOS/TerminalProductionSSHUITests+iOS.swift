#if os(iOS)
import XCTest

final class TerminalProductionSSHUITests: TerminalReconnectUITestCase {
    @MainActor
    func testProductionSSHBackgroundPreservesSessionKeyboardAndTyping() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "--vvterm-debug-log", "keyboard",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES",
            "-terminalTmuxEnabledDefault", "NO",
            "-terminalVoiceButtonEnabled", "YES",
            "-terminalUsePerAppearanceTheme", "NO",
            "-terminalThemeName", "Aizen Dark",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        if !diagnostics.waitForExistence(timeout: 5),
           app.state == .runningForeground {
            // Installing the app can cause ActivityKit to launch it once to
            // finish a stale Live Activity before XCUITest supplies our launch
            // arguments. Relaunch after installation so the harness owns the
            // process from its first scene.
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45), "Production reconnect harness did not mount")
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 45,
            app: app
        )
        wait(for: diagnostics, containing: "shell=true", timeout: 10, app: app)
        wait(for: diagnostics, containing: "title=DEV199_READY_1", timeout: 10, app: app)

        let terminal = app.descendants(matching: .any)
            .matching(identifier: "vvterm.reconnectTest.terminalSurface")
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        terminal.tap()
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)

        guard let initialTerminalId = diagnosticValue("terminalId", in: diagnostics) else {
            XCTFail("Missing terminal identity. \(diagnosticText(in: app))")
            return
        }
        guard let shellId = diagnosticValue("shellId", in: diagnostics), shellId != "none" else {
            XCTFail("Missing initial SSH shell identity. \(diagnosticText(in: app))")
            return
        }
        guard let initialInputRebuilds = diagnosticIntegerValue(
            "inputRebuilds",
            in: diagnostics
        ) else {
            XCTFail("Missing initial input-rebuild count. \(diagnosticText(in: app))")
            return
        }

        let initialKey = app.keys["x"]
        XCTAssertTrue(initialKey.waitForExistence(timeout: 5), diagnosticText(in: app))
        tapPromptly(initialKey, diagnostics: diagnostics, app: app)
        wait(for: diagnostics, containing: "cwd=/tmp/DEV199_INPUT_X_1", timeout: 8, app: app)

        for connectionNumber in 2...4 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(
                waitForBackgroundState(of: app, timeout: 8),
                "VVTerm did not enter the background. \(diagnosticText(in: app))"
            )
            let backgroundDuration: TimeInterval = connectionNumber == 2 ? 5 : 0.5
            RunLoop.current.run(until: Date().addingTimeInterval(backgroundDuration))

            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 8),
                "VVTerm did not return to the foreground. \(diagnosticText(in: app))"
            )
            wait(
                for: diagnostics,
                containing: "setup=ready state=connected",
                timeout: 30,
                app: app
            )
            wait(for: diagnostics, containing: "shell=true", timeout: 8, app: app)
            XCTAssertEqual(
                diagnosticValue("shellId", in: diagnostics),
                shellId,
                "Backgrounding replaced a live SSH shell. \(diagnosticText(in: app))"
            )
            wait(for: diagnostics, containing: "windowAttached=true", timeout: 8, app: app)
            wait(for: diagnostics, containing: "renderingPaused=false", timeout: 8, app: app)
            wait(for: diagnostics, containing: "surfaceFocused=true", timeout: 8, app: app)
            XCTAssertEqual(
                diagnosticValue("terminalId", in: diagnostics),
                initialTerminalId,
                "Foreground reconnect replaced the preserved Ghostty terminal. \(diagnosticText(in: app))"
            )
            assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
            XCTAssertEqual(
                diagnosticIntegerValue("inputRebuilds", in: diagnostics),
                initialInputRebuilds,
                "Backgrounding rebuilt the terminal input session. \(diagnosticText(in: app))"
            )

            let key = app.keys["x"]
            XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticText(in: app))
            tapPromptly(key, diagnostics: diagnostics, app: app)
            wait(
                for: diagnostics,
                containing: "cwd=/tmp/DEV199_INPUT_X_\(connectionNumber)",
                timeout: 8,
                app: app
            )
        }

    }

    @MainActor
    func testProductionSSHBackgroundPreservesDarkAccessoryAppearance() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(themeName: "Aizen Dark")
        defer { app.terminate() }

        let terminal = productionTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        wait(for: diagnostics, containing: "accessoryAppearance=dark", timeout: 5, app: app)

        guard let initialShellId = diagnosticValue("shellId", in: diagnostics) else {
            XCTFail("Missing initial SSH shell identity. \(diagnosticText(in: app))")
            return
        }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackgroundState(of: app, timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 30,
            app: app
        )
        XCTAssertEqual(
            diagnosticValue("shellId", in: diagnostics),
            initialShellId,
            "Backgrounding replaced the live SSH shell. \(diagnosticText(in: app))"
        )
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        wait(for: diagnostics, containing: "accessoryAppearance=dark", timeout: 5, app: app)
    }

    @MainActor
    func testProductionCodexModesKeepKeyboardAndPTYTyping() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness()
        defer { app.terminate() }
        wait(for: diagnostics, containing: "title=DEV199_READY_1", timeout: 10, app: app)

        let terminal = productionTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        let beforeCodex = try terminalSnapshot(in: diagnostics, app: app)

        enterCodexModes(through: terminal, diagnostics: diagnostics, app: app)
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        assertSameSession(as: beforeCodex, diagnostics: diagnostics, app: app)

        let key = app.keys["z"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticText(in: app))
        tapPromptly(key, diagnostics: diagnostics, app: app)
        wait(for: diagnostics, containing: "cwd=/tmp/DEV212_INPUT_Z_1", timeout: 8, app: app)

        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        assertSameSession(as: beforeCodex, diagnostics: diagnostics, app: app)
        finishProductionSSHTestHarness(app)
    }

    @MainActor
    func testProductionCodexFindKeyboardMenuRestoresPTYTyping() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(
            exposesKeyboardLossControl: true
        )
        defer { app.terminate() }
        wait(for: diagnostics, containing: "title=DEV199_READY_1", timeout: 10, app: app)

        let terminal = productionTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)

        enterCodexModes(through: terminal, diagnostics: diagnostics, app: app)
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        let beforeLoss = try terminalSnapshot(in: diagnostics, app: app)

        let lossControl = app.buttons["vvterm.reconnectTest.keyboard.unexpectedLoss"]
        XCTAssertTrue(lossControl.waitForExistence(timeout: 5), diagnosticText(in: app))
        lossControl.tap()
        wait(for: diagnostics, containing: "keyboardVisible=false", timeout: 8, app: app)
        wait(
            for: diagnostics,
            containing: "inputViewMode=testUnexpectedHidden",
            timeout: 5,
            app: app
        )
        wait(for: diagnostics, containing: "accessoryAttached=false", timeout: 5, app: app)
        wait(for: diagnostics, containing: "softwareInputActive=true", timeout: 5, app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
            "The real iOS keyboard remained visible after input loss. \(diagnosticText(in: app))"
        )

        openProductionTerminalMenu(in: app)
        let findItem = app.buttons["Find"]
        XCTAssertTrue(findItem.waitForExistence(timeout: 5), diagnosticText(in: app))
        findItem.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 8),
            "Native Find search field did not appear. \(diagnosticText(in: app))"
        )
        searchField.tap()
        wait(for: diagnostics, containing: "find=true", timeout: 5, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=false", timeout: 5, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))
        searchField.typeText("focus")
        XCTAssertEqual(searchField.value as? String, "focus", diagnosticText(in: app))

        // Preserve the Find keyboard's last visible frame even if opening the
        // production menu makes UIKit send a hide notification first. The
        // user's failure occurs when terminal reacquisition sees this stale
        // global frame and mistakes it for a healthy terminal keyboard.
        let staleFrameControl = app.buttons["vvterm.reconnectTest.keyboard.staleFindFrame"]
        XCTAssertTrue(staleFrameControl.waitForExistence(timeout: 5), diagnosticText(in: app))
        staleFrameControl.tap()
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 5, app: app)
        wait(for: diagnostics, containing: "find=true", timeout: 5, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=false", timeout: 5, app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "Find no longer owned a real software keyboard before repair. \(diagnosticText(in: app))"
        )

        openProductionTerminalMenu(in: app)
        let keyboardItem = app.buttons["Keyboard"]
        XCTAssertTrue(keyboardItem.waitForExistence(timeout: 5), diagnosticText(in: app))
        keyboardItem.tap()

        wait(for: diagnostics, containing: "find=false", timeout: 8, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 8, app: app)
        waitForDiagnosticInteger(
            "inputRebuilds",
            equalTo: beforeLoss.inputRebuilds + 1,
            in: diagnostics,
            timeout: 8,
            app: app
        )
        assertKeyboardAndAccessoryVisible(diagnostics: diagnostics, app: app)
        assertSameSession(
            terminalId: beforeLoss.terminalId,
            shellId: beforeLoss.shellId,
            diagnostics: diagnostics,
            app: app
        )

        let stabilityDeadline = Date().addingTimeInterval(2)
        while Date() < stabilityDeadline {
            XCTAssertEqual(
                diagnosticIntegerValue("inputRebuilds", in: diagnostics),
                beforeLoss.inputRebuilds + 1,
                "Keyboard repair rebuilt the input session more than once. \(diagnosticText(in: app))"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let key = app.keys["x"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), diagnosticText(in: app))
        tapPromptly(key, diagnostics: diagnostics, app: app)
        wait(for: diagnostics, containing: "cwd=/tmp/DEV212_INPUT_X_1", timeout: 8, app: app)
        assertSameSession(
            terminalId: beforeLoss.terminalId,
            shellId: beforeLoss.shellId,
            diagnostics: diagnostics,
            app: app
        )
        finishProductionSSHTestHarness(app)
    }

}
#endif
