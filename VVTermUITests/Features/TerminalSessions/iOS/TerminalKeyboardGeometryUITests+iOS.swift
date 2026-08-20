#if os(iOS)
import XCTest

final class TerminalKeyboardGeometryUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testDockedFloatingDockedGeometryKeepsSurfaceAndViewportValid() throws {
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
        let stableGridRows = try requiredDiagnosticMetric("gridRows", in: app)
        let stableGridResizes = try requiredDiagnosticMetric("gridResizes", in: app)
        for identifier in [
            "vvterm.keyboardTest.geometry.docked",
            "vvterm.keyboardTest.geometry.floating",
            "vvterm.keyboardTest.geometry.docked",
            "vvterm.keyboardTest.geometry.floating",
            "vvterm.keyboardTest.geometry.docked",
        ] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), diagnosticsText(in: app))
            button.tap()
            wait(
                for: diagnostics,
                labelContaining: "sizePreserved=true",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            XCTAssertEqual(
                try requiredDiagnosticMetric("gridRows", in: app),
                stableGridRows,
                diagnosticsText(in: app)
            )
            XCTAssertEqual(
                try requiredDiagnosticMetric("gridResizes", in: app),
                stableGridResizes,
                diagnosticsText(in: app)
            )
            assertTerminalViewportValid(in: app)
        }

        let hiddenButton = app.buttons["vvterm.keyboardTest.geometry.hidden"]
        XCTAssertTrue(hiddenButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        hiddenButton.tap()
        wait(
            for: diagnostics,
            labelContaining: "sizePreserved=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        terminal.typeText("g")
        wait(
            for: diagnostics,
            labelContaining: "inputHex=67",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
    }

    @MainActor
    func testDockedAccessoryUsesOwningTerminalDarkAppearance() throws {
        let app = launchKeyboardHarness(
            simulatesKeyboardFrames: true,
            simulatesDetachedLightAccessoryHost: true
        )
        let terminal = waitForTerminal(in: app)
        terminal.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let dockedButton = app.buttons["vvterm.keyboardTest.geometry.docked"]
        XCTAssertTrue(dockedButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        dockedButton.tap()

        for expectedDiagnostic in [
            "accessoryOwnerStyle=dark",
            "accessoryHostStyle=light",
            "accessoryResolvedStyle=dark",
            "accessoryAppearance=dark",
        ] {
            wait(
                for: diagnostics,
                labelContaining: expectedDiagnostic,
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
        }
    }

    @MainActor
    func testPrivacyResumeRestoresDockedAccessoryDarkAppearance() throws {
        let app = launchKeyboardHarness(
            privacyModeEnabled: true,
            simulatesKeyboardFrames: true,
            simulatesDetachedLightAccessoryHost: true,
            simulatesStaleLightAccessoryCacheOnResume: true
        )
        let terminal = waitForTerminal(in: app)
        terminal.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let dockedButton = app.buttons["vvterm.keyboardTest.geometry.docked"]
        XCTAssertTrue(dockedButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        dockedButton.tap()
        wait(
            for: diagnostics,
            labelContaining: "accessoryAppearance=dark",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.privacy.shield"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboardTest.privacyShield"]
                .waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )

        app.buttons["vvterm.keyboardTest.privacy.resume"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.keyboardTest.privacyShield"]
                .waitForNonExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        dockedButton.tap()
        wait(
            for: diagnostics,
            labelContaining: "cachedTerminalBackground=#ffffff",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        for expectedDiagnostic in [
            "reconnect=connected",
            "accessoryAttached=true",
            "accessoryOwnerStyle=dark",
            "accessoryHostStyle=light",
            "accessoryResolvedStyle=dark",
            "accessoryAppearance=dark",
        ] {
            wait(
                for: diagnostics,
                labelContaining: expectedDiagnostic,
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
        }
    }

    @MainActor
    func testDefaultLayoutClearsDockedInsetForEveryFloatingTransition() throws {
        let app = launchKeyboardHarness(
            preservesTerminalSize: false,
            simulatesKeyboardFrames: true
        )
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        app.buttons["vvterm.keyboardTest.geometry.hidden"].tap()
        wait(
            for: diagnostics,
            labelContaining: "keyboardVisible=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let unobstructedRows = try requiredDiagnosticMetric("gridRows", in: app)

        for _ in 0..<3 {
            app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
            waitForDiagnosticMetrics(in: app) { metrics in
                guard let rows = metrics["gridRows"] else { return false }
                return rows < unobstructedRows
            }

            app.buttons["vvterm.keyboardTest.geometry.floating"].tap()
            waitForDiagnosticMetrics(in: app) { metrics in
                metrics["gridRows"] == unobstructedRows
            }
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
        }
    }

    @MainActor
    func testFloatingKeyboardRoundTripDoesNotReloadInputViews() throws {
        let app = launchKeyboardHarness(simulatesKeyboardFrames: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        wait(
            for: diagnostics,
            labelContaining: "keyboardPresentation=docked",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryAttached=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessorySelfSizing=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryFittingHeight=48.0",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryHeight=48.0",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        let inputReloads = try requiredDiagnosticMetric("inputReloads", in: app)

        for identifier in [
            "vvterm.keyboardTest.geometry.floating",
            "vvterm.keyboardTest.geometry.docked",
            "vvterm.keyboardTest.geometry.floating",
            "vvterm.keyboardTest.geometry.docked",
        ] {
            app.buttons[identifier].tap()
            wait(
                for: diagnostics,
                labelContaining: identifier.hasSuffix("floating")
                    ? "keyboardPresentation=floating"
                    : "keyboardPresentation=docked",
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
                labelContaining: "accessoryAttached=true",
                timeout: 5,
                diagnostics: diagnosticsText(in: app)
            )
            XCTAssertEqual(
                try requiredDiagnosticMetric("inputReloads", in: app),
                inputReloads,
                diagnosticsText(in: app)
            )
            assertTerminalViewportValid(in: app)
        }
    }

    @MainActor
    func testNativeFloatingKeyboardRoundTripDoesNotReloadInputViews() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer {
            XCUIDevice.shared.orientation = .portrait
        }

        let app = launchKeyboardHarness()
        let terminal = waitForTerminal(in: app)
        terminal.tap()

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 8) else {
            throw XCTSkip(
                "Simulator suppressed the software keyboard. \(diagnosticsText(in: app))"
            )
        }

        let screenFrame = app.frame
        if keyboard.frame.width < screenFrame.width / 2 {
            guard dockFloatingKeyboard(keyboard, diagnostics: diagnostics, in: app) else {
                throw XCTSkip(
                    "Simulator did not support the native docking gesture. \(diagnosticsText(in: app))"
                )
            }
        }

        let accessory = app.descendants(matching: .any)[
            "vvterm.keyboard.accessory"
        ]
        XCTAssertTrue(
            accessory.waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        let inputReloads = try requiredDiagnosticMetric("inputReloads", in: app)

        guard makeKeyboardFloating(
            keyboard,
            diagnostics: diagnostics,
            screenWidth: screenFrame.width
        ) else {
            XCTFail(
                "Simulator did not perform the floating-keyboard gesture. \(diagnosticsText(in: app))"
            )
            return
        }
        XCTAssertTrue(
            accessory.exists,
            diagnosticsText(in: app)
        )
        XCTAssertEqual(
            try requiredDiagnosticMetric("inputReloads", in: app),
            inputReloads,
            """
            Floating transition rebuilt UIKit's input accessory hierarchy.
            \(diagnosticsText(in: app))
            """
        )
        assertTerminalViewportValid(in: app)

        let floatingKeyboardFrame = keyboard.frame
        XCTAssertLessThan(
            floatingKeyboardFrame.width,
            screenFrame.width / 2,
            diagnosticsText(in: app)
        )
        let floatingAccessoryFrame = accessory.frame
        if floatingAccessoryFrame.maxY >= screenFrame.maxY - 1,
           floatingAccessoryFrame.width >= screenFrame.width * 0.8 {
            XCTAssertLessThanOrEqual(
                terminal.frame.maxY,
                floatingAccessoryFrame.minY + 1,
                """
                Terminal extends beneath the bottom-docked accessory while the keyboard is floating.
                terminal=\(terminal.frame) accessory=\(floatingAccessoryFrame)
                \(diagnosticsText(in: app))
                """
            )
        }
        guard dockFloatingKeyboard(keyboard, diagnostics: diagnostics, in: app) else {
            throw XCTSkip(
                "Simulator did not support the native redocking gesture. \(diagnosticsText(in: app))"
            )
        }
        XCTAssertTrue(
            accessory.exists,
            diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "accessoryHeight=48.0",
            timeout: 8,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertEqual(
            try requiredDiagnosticMetric("inputReloads", in: app),
            inputReloads,
            """
            Docked transition reloaded UIKit's input accessory hierarchy.
            \(diagnosticsText(in: app))
            """
        )
        assertTerminalViewportValid(in: app)
        XCTAssertGreaterThan(
            keyboard.frame.width,
            screenFrame.width * 0.8,
            diagnosticsText(in: app)
        )
        XCTAssertLessThanOrEqual(
            accessory.frame.maxY,
            keyboard.frame.minY + 1,
            """
            Accessory overlaps the docked keyboard.
            accessory=\(accessory.frame) keyboard=\(keyboard.frame)
            \(diagnosticsText(in: app))
            """
        )
    }

    @MainActor
    func testPreservedTerminalGridMovesCursorAboveKeyboard() throws {
        let app = launchKeyboardHarness(preservesTerminalSize: true)
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        assertKeyboardAndAccessoryVisible(in: app)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        assertKeyboardAndAccessoryHidden(in: app)
        let expandedRows = try requiredDiagnosticMetric("gridRows", in: app)
        let restingTerminalTop = try requiredDiagnosticMetric("terminalTop", in: app)

        let transitionBaseline = try keyboardTransitionBaseline(in: app)
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        assertKeyboardAndAccessoryVisible(in: app)
        app.buttons["vvterm.keyboardTest.cursor.bottom"].tap()

        waitForDiagnosticMetrics(in: app) { metrics in
            guard let rows = metrics["gridRows"],
                  let terminalTop = metrics["terminalTop"],
                  let cursorBottom = metrics["cursorBottom"],
                  let keyboardTop = metrics["keyboardTop"]
            else {
                return false
            }
            return rows == expandedRows
                && terminalTop < restingTerminalTop
                && cursorBottom <= keyboardTop
        }
        assertSingleKeyboardRestore(since: transitionBaseline, in: app)
    }
}
#endif

