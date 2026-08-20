#if os(iOS)
import XCTest

class TerminalReconnectUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    struct TerminalSnapshot {
        let terminalId: String
        let shellId: String
        let inputRebuilds: Int
    }

    @MainActor
    func launchProductionSSHTestHarness(
        exposesKeyboardLossControl: Bool = false,
        themeName: String? = nil
    ) -> (XCUIApplication, XCUIElement) {
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
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        if let themeName {
            app.launchArguments += [
                "-terminalUsePerAppearanceTheme", "NO",
                "-terminalThemeName", themeName,
            ]
        }
        if exposesKeyboardLossControl {
            app.launchArguments += [
                "--vvterm-ui-test-unexpected-keyboard-loss-control",
                "--vvterm-ui-test-simulate-keyboard-frames",
            ]
        }
        app.launch()

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        if !diagnostics.waitForExistence(timeout: 5),
           app.state == .runningForeground {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(
            diagnostics.waitForExistence(timeout: 45),
            "Production SSH harness did not mount"
        )
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 45,
            app: app
        )
        wait(for: diagnostics, containing: "shell=true", timeout: 10, app: app)
        return (app, diagnostics)
    }

    @MainActor
    func productionTerminal(in app: XCUIApplication) -> XCUIElement {
        let terminal = app.descendants(matching: .any)
            .matching(identifier: "vvterm.reconnectTest.terminalSurface")
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        return terminal
    }

    @MainActor
    func enterCodexModes(
        through terminal: XCUIElement,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertTrue(terminal.exists, diagnosticText(in: app))
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 5, app: app)
        terminal.typeText("hello")
        let returnKey = app.buttons["Return"]
        XCTAssertTrue(returnKey.waitForExistence(timeout: 5), diagnosticText(in: app))
        returnKey.tap()
        wait(
            for: diagnostics,
            containing: "title=DEV212_CODEX_READY_1",
            timeout: 8,
            app: app
        )
    }

    @MainActor
    func finishProductionSSHTestHarness(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        _ = waitForBackgroundState(of: app, timeout: 8)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    func openProductionTerminalMenu(in app: XCUIApplication) {
        let menu = app.navigationBars.firstMatch.buttons["vvterm.terminal.moreMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), diagnosticText(in: app))
        menu.tap()
    }

    @MainActor
    func terminalSnapshot(
        in diagnostics: XCUIElement,
        app: XCUIApplication
    ) throws -> TerminalSnapshot {
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 8,
            app: app
        )
        wait(for: diagnostics, containing: "shell=true", timeout: 8, app: app)
        let terminalId = try XCTUnwrap(
            diagnosticValue("terminalId", in: diagnostics),
            "Missing terminal identity. \(diagnosticText(in: app))"
        )
        let shellId = try XCTUnwrap(
            diagnosticValue("shellId", in: diagnostics),
            "Missing SSH shell identity. \(diagnosticText(in: app))"
        )
        let inputRebuilds = try XCTUnwrap(
            diagnosticIntegerValue("inputRebuilds", in: diagnostics),
            "Missing input rebuild count. \(diagnosticText(in: app))"
        )
        XCTAssertNotEqual(shellId, "none", diagnosticText(in: app))
        return TerminalSnapshot(
            terminalId: terminalId,
            shellId: shellId,
            inputRebuilds: inputRebuilds
        )
    }

    @MainActor
    func assertSameSession(
        as snapshot: TerminalSnapshot,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        assertSameSession(
            terminalId: snapshot.terminalId,
            shellId: snapshot.shellId,
            diagnostics: diagnostics,
            app: app
        )
        XCTAssertEqual(
            diagnosticIntegerValue("inputRebuilds", in: diagnostics),
            snapshot.inputRebuilds,
            diagnosticText(in: app)
        )
    }

    @MainActor
    func assertSameSession(
        terminalId: String,
        shellId: String,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertEqual(
            diagnosticValue("terminalId", in: diagnostics),
            terminalId,
            diagnosticText(in: app)
        )
        XCTAssertEqual(
            diagnosticValue("shellId", in: diagnostics),
            shellId,
            diagnosticText(in: app)
        )
    }

    @MainActor
    func waitForDiagnosticInteger(
        _ name: String,
        equalTo expected: Int,
        in diagnostics: XCUIElement,
        timeout: TimeInterval,
        app: XCUIApplication
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if diagnosticIntegerValue(name, in: diagnostics) == expected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail(
            "Expected \(name)=\(expected). \(diagnosticText(in: app))"
        )
    }

    @MainActor
    func tapPromptly(
        _ key: XCUIElement,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        let startedAt = Date()
        key.tap()
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            10,
            "Software-keyboard input stalled. \(diagnosticText(in: app))"
        )
    }

    @MainActor
    func assertKeyboardAndAccessoryVisible(
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        wait(for: diagnostics, containing: "keyWindow=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "softwareInputActive=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "inputViewMode=system", timeout: 8, app: app)
        wait(for: diagnostics, containing: "accessoryAttached=true", timeout: 8, app: app)
        wait(for: diagnostics, containing: "hardware=false", timeout: 8, app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "The real iOS software keyboard was not visible. \(diagnosticText(in: app))"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboard.accessory.hide"]
                .waitForExistence(timeout: 5),
            diagnosticText(in: app)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboard.accessory.voice"]
                .waitForExistence(timeout: 5),
            "The terminal voice button was not stable. \(diagnosticText(in: app))"
        )
    }

    @MainActor
    func wait(
        for element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval,
        app: XCUIApplication
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(expected) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected diagnostics to contain '\(expected)'. \(diagnosticText(in: app))")
    }

    @MainActor
    func diagnosticValue(_ name: String, in diagnostics: XCUIElement) -> String? {
        diagnostics.label
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    @MainActor
    func diagnosticIntegerValue(_ name: String, in diagnostics: XCUIElement) -> Int? {
        diagnosticValue(name, in: diagnostics).flatMap(Int.init)
    }

    @MainActor
    func waitForBackgroundState(of app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    func waitForChangedDiagnosticValue(
        _ name: String,
        previousValue: String,
        in diagnostics: XCUIElement,
        timeout: TimeInterval,
        app: XCUIApplication
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = diagnosticValue(name, in: diagnostics),
               value != "none",
               value != previousValue {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected \(name) to change from \(previousValue). \(diagnosticText(in: app))")
        return nil
    }

    @MainActor
    func diagnosticText(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        return diagnostics.exists ? diagnostics.label : "diagnostics unavailable; app state=\(app.state.rawValue)"
    }
}
#endif
