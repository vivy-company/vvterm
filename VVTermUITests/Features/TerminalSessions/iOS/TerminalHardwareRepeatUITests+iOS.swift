#if os(iOS)
import XCTest

final class TerminalHardwareRepeatUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testPrintableHardwareKeyRepeatOwnsResolvedTextUntilReleaseOrCancel() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardware=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.begin.h"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 1,
            uppercaseHInputs: 0,
            in: app
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=1",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 3,
            uppercaseHInputs: 0,
            in: app
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.release"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardwareRepeatPhase=idle",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=0",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        assertHardwareRepeatInputCountsRemain(
            lowercaseHInputs: 3,
            uppercaseHInputs: 0,
            in: app
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.begin.shiftH"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 3,
            uppercaseHInputs: 1,
            in: app
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=2",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 3,
            uppercaseHInputs: 3,
            in: app
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.cancel"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardwareRepeatPhase=idle",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=0",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        assertHardwareRepeatInputCountsRemain(
            lowercaseHInputs: 3,
            uppercaseHInputs: 3,
            in: app
        )
    }

    @MainActor
    func testBackgroundLifecycleStopsPrintableHardwareKeyRepeat() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        terminal.tap()
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardware=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.begin.shiftH"].tap()
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 0,
            uppercaseHInputs: 2,
            in: app
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=2",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

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
            labelContaining: "reconnect=connected",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwareRepeatPhase=idle",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=0",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        assertHardwareRepeatInputCountsRemain(
            lowercaseHInputs: 0,
            uppercaseHInputs: 2,
            in: app
        )
    }

    @MainActor
    func testHardwareKeyboardDetachStopsPrintableHardwareKeyRepeat() throws {
        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        terminal.tap()
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardware=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.begin.h"].tap()
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 2,
            uppercaseHInputs: 0,
            in: app
        )

        app.buttons["vvterm.keyboardTest.hardware.detach"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardware=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwareRepeatPhase=idle",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=0",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        assertHardwareRepeatInputCountsRemain(
            lowercaseHInputs: 2,
            uppercaseHInputs: 0,
            in: app
        )
    }

    @MainActor
    func testIMECompositionStopsPrintableHardwareKeyRepeat() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        terminal.tap()
        app.buttons["vvterm.keyboardTest.hardware.attach"].tap()
        wait(
            for: diagnostics,
            labelContaining: "hardware=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.begin.shiftH"].tap()
        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        waitForHardwareRepeat(
            phase: "repeating",
            lowercaseHInputs: 0,
            uppercaseHInputs: 2,
            in: app
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=2",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.ime.mark"].tap()
        wait(
            for: diagnostics,
            labelContaining: "imeComposing=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "imeMarkedText=nihon",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwareRepeatPhase=idle",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "hardwarePresses=0",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.hardwareRepeat.tick"].tap()
        assertHardwareRepeatInputCountsRemain(
            lowercaseHInputs: 0,
            uppercaseHInputs: 2,
            in: app
        )
    }

}
#endif

