#if os(iOS)
import XCTest

final class TerminalPointerSelectionUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testDirectTouchRoutesBalancedClicksWithoutGestureDuplicates() throws {
        let app = launchKeyboardHarness(simulatesTerminalMouseCapture: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "mouseCaptured=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)

        terminal.tap()
        waitForMouseClickCounts(presses: 1, releases: 1, in: app)
        wait(
            for: diagnostics,
            labelContaining: "terminalFirstResponder=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        wait(
            for: diagnostics,
            labelContaining: "imeProxyFirstResponder=true",
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

        let dragStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let dragEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["mouseScrollReports"] ?? 0) > 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)

        let gestureSurface = app.descendants(matching: .any)["vvterm.keyboardTest.gestureSurface"]
        XCTAssertTrue(
            gestureSurface.waitForExistence(timeout: 5),
            diagnosticsText(in: app)
        )
        gestureSurface.pinch(withScale: 0.8, velocity: -1)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["zoomActions"] ?? 0) > 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) > 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) == 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        waitForMouseClickCounts(presses: 2, releases: 2, in: app)
        terminal.tap()
        waitForMouseClickCounts(presses: 3, releases: 3, in: app)
    }

    @MainActor
    func testCapturedLongPressUsesNativeSelectionAndPasteWithoutSendingClick() throws {
        let app = launchKeyboardHarness(
            simulatesKeyboardFrames: true,
            simulatesTerminalMouseCapture: true,
            seedsTerminalPasteboard: true
        )
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "mouseCaptured=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        terminal.tap()
        waitForMouseClickCounts(presses: 1, releases: 1, in: app)
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        assertKeyboardSessionAndAccessoryVisible(in: app)

        let dragStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let dragEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["mouseScrollReports"] ?? 0) > 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)

        let selectionStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let selectionEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        selectionStart.press(forDuration: 1, thenDragTo: selectionEnd)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) > 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
        assertKeyboardSessionAndAccessoryVisible(in: app)

        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), diagnosticsText(in: app))
        paste.tap()
        wait(
            for: diagnostics,
            labelContaining: "inputHex=746f7563682d7061737465",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertKeyboardSessionAndAccessoryVisible(in: app)
        XCTAssertTrue(paste.waitForNonExistence(timeout: 5), diagnosticsText(in: app))
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
    }

    @MainActor
    func testCapturedMultiTapUsesNativeSelectionWithoutSendingClick() throws {
        let app = launchKeyboardHarness(simulatesTerminalMouseCapture: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]

        terminal.tap()
        waitForMouseClickCounts(presses: 1, releases: 1, in: app)

        terminal.doubleTap()
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) > 0
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
        let doubleTapSelectionLength = try requiredDiagnosticMetric(
            "nativeSelectionLength",
            in: app
        )

        terminal.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) > doubleTapSelectionLength
        }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) == 0
        }
        wait(
            for: diagnostics,
            labelContaining: "nativeSelectionActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
    }

    @MainActor
    func testDirectTouchDoesNotClickOutsideMouseCapture() throws {
        let app = launchKeyboardHarness(seedsTerminalSelectionFixture: true)
        let terminal = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "mouseCaptured=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )

        terminal.tap()
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)
        wait(
            for: diagnostics,
            labelContaining: "terminalFirstResponder=true",
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
            labelContaining: "nativeSelectionActive=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertEqual(
            try requiredDiagnosticMetric("nativeSelectionLength", in: app),
            0,
            diagnosticsText(in: app)
        )

        terminal.doubleTap()
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) > 0
        }
        let doubleTapSelectionLength = try requiredDiagnosticMetric(
            "nativeSelectionLength",
            in: app
        )

        terminal.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)
        waitForDiagnosticMetrics(in: app) { metrics in
            (metrics["nativeSelectionLength"] ?? 0) > doubleTapSelectionLength
        }
    }

}
#endif

