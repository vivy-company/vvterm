#if os(iOS)
import XCTest

final class TerminalHardwareKeyboardUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testTouchingTerminalRequestsPaneFocus() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        wait(for: diagnostics, labelContaining: "paneFocusActions=0", timeout: 5, diagnostics: diagnosticsText(in: app))
        terminal.tap()
        wait(for: diagnostics, labelContaining: "paneFocusActions=1", timeout: 5, diagnostics: diagnosticsText(in: app))
    }

    @MainActor
    func testHardwareKeyboardFocusSuppressesAccessoryBar() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        app.buttons["vvterm.keyboardTest.hardwareFocus"].tap()
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)
    }

    @MainActor
    func testHardwareKeyboardAttachmentHidesAccessoryFromExistingSoftwareSession() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)

        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)

        terminal.typeText("x")
        wait(for: diagnostics, labelContaining: "inputHex=78", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)

        app.buttons["vvterm.keyboardTest.hardware.detach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryVisible(in: app)
    }

    @MainActor
    func testExplicitKeyboardCommandMaintainsForcedPolicyWhileHardwareRemainsAttached() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardForced=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)

        let firstRestoreBaseline = try keyboardTransitionBaseline(in: app)
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            metrics["inputRebuilds"] == firstRestoreBaseline.rebuilds + 1
        }
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardForced=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessorySuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        terminal.typeText("h")
        wait(for: diagnostics, labelContaining: "inputHex=68", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.hardwareFocus"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardForced=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app))

        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardForced=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertSingleKeyboardRepair(since: firstRestoreBaseline, in: app)

        app.buttons["vvterm.keyboardTest.geometry.hidden"].tap()
        wait(for: diagnostics, labelContaining: "keyboardForced=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessorySuppressed=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))

        let forcedRetryBaseline = try keyboardTransitionBaseline(in: app)
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            metrics["inputRebuilds"] == forcedRetryBaseline.rebuilds + 1
        }
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(for: diagnostics, labelContaining: "keyboardForced=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessorySuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertSingleKeyboardRepair(since: forcedRetryBaseline, in: app)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardForced=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryHidden=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)

        let secondRestoreBaseline = try keyboardTransitionBaseline(in: app)
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(for: diagnostics, labelContaining: "hardware=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardForced=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareKeyboardSuppressed=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertSingleKeyboardRestore(since: secondRestoreBaseline, in: app)
    }

    @MainActor
    func testDefaultKeyboardAvoidanceResizesTerminalGrid() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        assertKeyboardAndAccessoryHidden(in: app)
        let expandedRows = try requiredDiagnosticMetric("gridRows", in: app)

        let transitionBaseline = try keyboardTransitionBaseline(in: app)
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        assertKeyboardAndAccessoryVisible(in: app)
        waitForDiagnosticMetrics(in: app) { metrics in
            guard let rows = metrics["gridRows"],
                  let terminalBottom = metrics["terminalBottom"],
                  let keyboardTop = metrics["keyboardTop"] else { return false }
            return rows < expandedRows && terminalBottom <= keyboardTop + 1
        }
        assertSingleKeyboardRestore(since: transitionBaseline, in: app)
    }

    @MainActor
    func testRepeatedFocusTapsKeepDefaultKeyboardAndLayoutStable() throws {
        let app = launchKeyboardHarness(preservesTerminalSize: false)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        for _ in 0..<8 {
            terminal.tap()
        }
        assertKeyboardAndAccessoryVisible(in: app)

        let stableRows = try requiredDiagnosticMetric("gridRows", in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            XCTAssertTrue(app.keyboards.firstMatch.exists, diagnosticsText(in: app))
            XCTAssertTrue(diagnostics.label.contains("keyboardVisible=true"), diagnosticsText(in: app))
            XCTAssertTrue(diagnostics.label.contains("accessoryAttached=true"), diagnosticsText(in: app))
            XCTAssertEqual(
                try requiredDiagnosticMetric("gridRows", in: app),
                stableRows,
                diagnosticsText(in: app)
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

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

