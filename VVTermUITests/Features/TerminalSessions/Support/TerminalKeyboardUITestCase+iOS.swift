#if os(iOS)
import XCTest

class TerminalKeyboardUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    func makeKeyboardFloating(
        _ keyboard: XCUIElement,
        diagnostics: XCUIElement,
        screenWidth: CGFloat
    ) -> Bool {
        for scale: CGFloat in [0.5, 0.35, 0.25] {
            keyboard.pinch(withScale: scale, velocity: -2)
            guard waitForLabel(
                diagnostics,
                containing: "keyboardPresentation=floating",
                timeout: 3
            ) else {
                continue
            }
            if waitForKeyboardFrame(keyboard, timeout: 3, matching: { frame in
                frame.width < screenWidth / 2
            }) {
                return true
            }
        }
        return false
    }

    func dockFloatingKeyboard(
        _ keyboard: XCUIElement,
        diagnostics: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        let screenFrame = app.frame
        keyboard.pinch(withScale: 2, velocity: 2)
        if waitForLabel(
            diagnostics,
            containing: "keyboardPresentation=docked",
            timeout: 5
        ), waitForKeyboardFrame(keyboard, timeout: 5, matching: { frame in
            frame.width > screenFrame.width * 0.8
        }) {
            return true
        }

        let currentKeyboard = app.keyboards.firstMatch
        guard currentKeyboard.waitForExistence(timeout: 2) else { return false }
        let keyboardFrame = currentKeyboard.frame
        let dragStart = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: keyboardFrame.midX / screenFrame.width,
                dy: min(keyboardFrame.maxY - 12, screenFrame.maxY - 12) / screenFrame.height
            )
        )
        let dragEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)
        )
        dragStart.press(
            forDuration: 0.5,
            thenDragTo: dragEnd,
            withVelocity: .slow,
            thenHoldForDuration: 1
        )
        return waitForLabel(
            diagnostics,
            containing: "keyboardPresentation=docked",
            timeout: 5
        ) && waitForKeyboardFrame(currentKeyboard, timeout: 5, matching: { frame in
            frame.width > screenFrame.width * 0.8
        })
    }

    func waitForKeyboardFrame(
        _ keyboard: XCUIElement,
        timeout: TimeInterval,
        matching predicate: (CGRect) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if keyboard.exists, predicate(keyboard.frame) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func waitForBackgroundState(
        of app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
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
    func launchKeyboardHarness(
        preservesTerminalSize: Bool = false,
        privacyModeEnabled: Bool = false,
        simulatesKeyboardFrames: Bool = false,
        simulatesCodexTUIResponse: Bool = false,
        simulatesTerminalMouseCapture: Bool = false,
        seedsTerminalSelectionFixture: Bool = false,
        seedsTerminalPasteboard: Bool = false,
        simulatesDetachedLightAccessoryHost: Bool = false,
        simulatesStaleLightAccessoryCacheOnResume: Bool = false,
        splitPaneFocus: Bool = false,
        testsAppShortcutInputs: Bool = false,
        simulatesTerminalMetadataChurn: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-keyboard-harness",
            "--vvterm-debug-log", "keyboard",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-security.privacyModeEnabled", privacyModeEnabled ? "YES" : "NO"
        ]
        if splitPaneFocus {
            app.launchArguments.append("--vvterm-ui-test-terminal-split-keyboard-harness")
        }
        if testsAppShortcutInputs {
            app.launchArguments.append("--vvterm-ui-test-terminal-app-shortcut-inputs")
        }
        if simulatesTerminalMetadataChurn {
            app.launchArguments.append("--vvterm-ui-test-terminal-metadata-churn")
        }
        if preservesTerminalSize {
            app.launchArguments.append("--vvterm-ui-test-preserve-terminal-size")
        }
        if simulatesKeyboardFrames {
            app.launchArguments.append("--vvterm-ui-test-simulate-keyboard-frames")
        }
        if simulatesCodexTUIResponse {
            app.launchArguments.append("--vvterm-ui-test-codex-tui-response")
        }
        if simulatesTerminalMouseCapture {
            app.launchArguments.append("--vvterm-ui-test-terminal-mouse-capture")
        }
        if seedsTerminalSelectionFixture {
            app.launchArguments.append("--vvterm-ui-test-terminal-selection-fixture")
        }
        if seedsTerminalPasteboard {
            app.launchArguments.append("--vvterm-ui-test-terminal-pasteboard")
        }
        if simulatesDetachedLightAccessoryHost {
            app.launchArguments += [
                "--vvterm-ui-test-detached-light-accessory-host",
                "--vvterm-ui-test-clear-terminal-background-cache",
                "-appearanceMode", "dark",
                "-terminalUsePerAppearanceTheme", "YES",
                "-terminalThemeName", "Aizen Dark",
                "-terminalThemeNameLight", "Aizen Light"
            ]
        }
        if simulatesStaleLightAccessoryCacheOnResume {
            app.launchArguments.append(
                "--vvterm-ui-test-stale-light-accessory-cache-on-resume"
            )
        }
        app.launch()

        let ready = app.staticTexts["vvterm.keyboardTest.ready"]
        let readinessTimeout: TimeInterval = 45
        XCTAssertTrue(
            ready.waitForExistence(timeout: readinessTimeout),
            "Keyboard harness did not mount"
        )
        wait(
            for: ready,
            labelContaining: "ready=true",
            timeout: readinessTimeout,
            diagnostics: diagnosticsText(in: app)
        )
        return app
    }

    @MainActor
    func waitForTerminal(in app: XCUIApplication) -> XCUIElement {
        let terminal = app.descendants(matching: .any)
            .matching(identifier: "vvterm.keyboardTest.terminalSurface")
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticsText(in: app))
        return terminal
    }

    @MainActor
    func openSettingsSheet(in app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons["vvterm.keyboardTest.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), diagnosticsText(in: app))
        menu.tap()

        let settingsItem = app.descendants(matching: .any)["vvterm.keyboardTest.menu.settings"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), diagnosticsText(in: app))
        settingsItem.tap()

        let settingsSheet = app.descendants(matching: .any)["vvterm.keyboardTest.settings.sheet"]
        XCTAssertTrue(settingsSheet.waitForExistence(timeout: 5), diagnosticsText(in: app))
        return settingsSheet
    }

    @MainActor
    func closeSettingsSheet(
        _ settingsSheet: XCUIElement,
        in app: XCUIApplication
    ) {
        let closeButton = app.buttons["vvterm.keyboardTest.settings.close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        closeButton.tap()
        XCTAssertTrue(settingsSheet.waitForNonExistence(timeout: 5), diagnosticsText(in: app))
    }

    @MainActor
    func requestKeyboardFromMenu(in app: XCUIApplication) {
        let menu = app.buttons["vvterm.keyboardTest.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), diagnosticsText(in: app))
        menu.tap()

        let keyboardItem = app.descendants(matching: .any)["vvterm.keyboardTest.menu.showKeyboard"]
        XCTAssertTrue(keyboardItem.waitForExistence(timeout: 5), diagnosticsText(in: app))
        keyboardItem.tap()
    }

    @MainActor
    func induceUnexpectedKeyboardLoss(
        in app: XCUIApplication
    ) throws -> KeyboardTransitionBaseline {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        let lossButton = app.buttons["vvterm.keyboardTest.keyboard.unexpectedLoss"]
        XCTAssertTrue(lossButton.waitForExistence(timeout: 5), diagnosticsText(in: app))
        lossButton.tap()

        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 8, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "inputViewMode=testUnexpectedHidden", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessorySuppressed=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "hardware=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "browse=false", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "hideRequests=0", timeout: 5, diagnostics: diagnosticsText(in: app))
        assertKeyboardAndAccessoryHidden(in: app)
        return try keyboardTransitionBaseline(in: app)
    }

    @MainActor
    func repairUnexpectedKeyboardLossFromMenu(
        since baseline: KeyboardTransitionBaseline,
        in app: XCUIApplication
    ) {
        requestKeyboardFromMenu(in: app)
        waitForDiagnosticMetrics(in: app) { metrics in
            metrics["inputRebuilds"] == baseline.rebuilds + 1
        }
        assertKeyboardAndAccessoryVisible(in: app)
        assertSingleKeyboardRepair(since: baseline, in: app)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "accessoryPairingObservation=completed",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertTrue(
            diagnostics.label.contains("orphanAccessoryObserved=false"),
            "The keyboard repair exposed an accessory without its software keyboard. \(diagnosticsText(in: app))"
        )
    }

    func assertKeyboardAndAccessoryVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "imeProxyFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)

        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            """
            Software keyboard did not appear.
            \(diagnosticsText(in: app))
            """,
            file: file,
            line: line
        )
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
    }

    func assertKeyboardSessionAndAccessoryVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "softwareInputActive=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "terminalFirstResponder=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "keyboardVisible=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "accessoryAttached=true", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
    }

    func assertKeyboardAndAccessoryHidden(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
            """
            Software keyboard did not hide with the accessory.
            \(diagnosticsText(in: app))
            """,
            file: file,
            line: line
        )
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "keyboardVisible=false", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
        wait(for: diagnostics, labelContaining: "accessoryAttached=false", timeout: 5, diagnostics: diagnosticsText(in: app), file: file, line: line)
    }

    func assertKeyboardAndAccessoryRemainHidden(
        in app: XCUIApplication,
        duration: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertKeyboardAndAccessoryHidden(in: app, file: file, line: line)

        let deadline = Date().addingTimeInterval(duration)
        let keyboard = app.keyboards.firstMatch
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        while Date() < deadline {
            if keyboard.exists || diagnostics.label.contains("keyboardVisible=true") || diagnostics.label.contains("accessoryAttached=true") {
                XCTFail(
                    """
                    Software keyboard or accessory reappeared after terminal tap.
                    \(diagnosticsText(in: app))
                    """,
                    file: file,
                    line: line
                )
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func assertTerminalViewportValid(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let metrics = diagnosticMetrics(in: app)
        let diagnostics = diagnosticsText(in: app)
        XCTAssertGreaterThan(
            metrics["visibleTerminalHeight"] ?? 0,
            0,
            diagnostics,
            file: file,
            line: line
        )
        XCTAssertGreaterThan(metrics["gridCols"] ?? 0, 0, diagnostics, file: file, line: line)
        XCTAssertGreaterThan(metrics["gridRows"] ?? 0, 0, diagnostics, file: file, line: line)
    }

    func waitForMouseClickCounts(
        presses: Double,
        releases: Double,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForDiagnosticMetrics(in: app, file: file, line: line) { metrics in
            metrics["primaryMousePresses"] == presses
                && metrics["primaryMouseReleases"] == releases
        }
    }

    func assertMouseClickCountsRemain(
        presses: Double,
        releases: Double,
        in app: XCUIApplication,
        duration: TimeInterval = 0.6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let metrics = diagnosticMetrics(in: app)
            XCTAssertEqual(metrics["primaryMousePresses"], presses, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["primaryMouseReleases"], releases, diagnosticsText(in: app), file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func waitForHardwareRepeat(
        phase: String,
        lowercaseHInputs: Double,
        uppercaseHInputs: Double,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "hardwareRepeatPhase=\(phase)",
            timeout: 5,
            diagnostics: diagnosticsText(in: app),
            file: file,
            line: line
        )
        waitForDiagnosticMetrics(in: app, file: file, line: line) { metrics in
            metrics["lowercaseHInputs"] == lowercaseHInputs
                && metrics["uppercaseHInputs"] == uppercaseHInputs
        }
    }

    func assertHardwareRepeatInputCountsRemain(
        lowercaseHInputs: Double,
        uppercaseHInputs: Double,
        in app: XCUIApplication,
        duration: TimeInterval = 0.6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let metrics = diagnosticMetrics(in: app)
            XCTAssertEqual(
                metrics["lowercaseHInputs"],
                lowercaseHInputs,
                diagnosticsText(in: app),
                file: file,
                line: line
            )
            XCTAssertEqual(
                metrics["uppercaseHInputs"],
                uppercaseHInputs,
                diagnosticsText(in: app),
                file: file,
                line: line
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func wait(
        for element: XCUIElement,
        labelContaining expectedText: String,
        timeout: TimeInterval,
        diagnostics: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !waitForLabel(element, containing: expectedText, timeout: timeout) else { return }
        XCTFail(
            """
            Timed out waiting for \(expectedText).
            \(diagnostics())
            """,
            file: file,
            line: line
        )
    }

    func waitForLabel(
        _ element: XCUIElement,
        containing expectedText: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func diagnosticsText(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        guard diagnostics.exists else { return "diagnostics=<missing>" }
        return "diagnostics=\(diagnostics.label)"
    }

    func requiredDiagnosticMetric(
        _ name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        let metrics = diagnosticMetrics(in: app)
        guard let value = metrics[name] else {
            XCTFail("Missing diagnostic metric \(name). \(diagnosticsText(in: app))", file: file, line: line)
            throw DiagnosticMetricError.missing(name)
        }
        return value
    }

    struct KeyboardTransitionBaseline {
        let shows: Double
        let hides: Double
        let rebuilds: Double
    }

    func keyboardTransitionBaseline(in app: XCUIApplication) throws -> KeyboardTransitionBaseline {
        KeyboardTransitionBaseline(
            shows: try requiredDiagnosticMetric("keyboardShows", in: app),
            hides: try requiredDiagnosticMetric("keyboardHides", in: app),
            rebuilds: try requiredDiagnosticMetric("inputRebuilds", in: app)
        )
    }

    func assertSingleKeyboardRestore(
        since baseline: KeyboardTransitionBaseline,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForDiagnosticMetrics(in: app, file: file, line: line) { metrics in
            metrics["keyboardShows"] == baseline.shows + 1
                && metrics["keyboardHides"] == baseline.hides
                && metrics["inputRebuilds"] == baseline.rebuilds
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let metrics = diagnosticMetrics(in: app)
            assertTerminalOwnsVisibleKeyboard(in: app, file: file, line: line)
            XCTAssertEqual(metrics["keyboardShows"], baseline.shows + 1, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["keyboardHides"], baseline.hides, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["inputRebuilds"], baseline.rebuilds, diagnosticsText(in: app), file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func assertSingleKeyboardRepair(
        since baseline: KeyboardTransitionBaseline,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForDiagnosticMetrics(in: app, file: file, line: line) { metrics in
            metrics["keyboardShows"] == baseline.shows + 1
                && metrics["keyboardHides"] == baseline.hides
                && metrics["inputRebuilds"] == baseline.rebuilds + 1
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let metrics = diagnosticMetrics(in: app)
            assertTerminalOwnsVisibleKeyboard(in: app, file: file, line: line)
            XCTAssertEqual(metrics["keyboardShows"], baseline.shows + 1, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["keyboardHides"], baseline.hides, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["inputRebuilds"], baseline.rebuilds + 1, diagnosticsText(in: app), file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func assertKeyboardStateStable(
        since baseline: KeyboardTransitionBaseline,
        in app: XCUIApplication,
        duration: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let metrics = diagnosticMetrics(in: app)
            assertTerminalOwnsVisibleKeyboard(in: app, file: file, line: line)
            XCTAssertEqual(metrics["keyboardShows"], baseline.shows, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["keyboardHides"], baseline.hides, diagnosticsText(in: app), file: file, line: line)
            XCTAssertEqual(metrics["inputRebuilds"], baseline.rebuilds, diagnosticsText(in: app), file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func assertTerminalOwnsVisibleKeyboard(
        in app: XCUIApplication,
        file: StaticString,
        line: UInt
    ) {
        let diagnostics = diagnosticsText(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists, diagnostics, file: file, line: line)
        for expected in [
            "keyboardVisible=true",
            "accessoryAttached=true",
            "accessorySuppressed=false",
            "imeProxyFirstResponder=true",
        ] {
            XCTAssertTrue(diagnostics.contains(expected), diagnostics, file: file, line: line)
        }
    }

    func waitForDiagnosticMetrics(
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: ([String: Double]) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(diagnosticMetrics(in: app)) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Timed out waiting for terminal geometry. \(diagnosticsText(in: app))", file: file, line: line)
    }

    func diagnosticMetrics(in app: XCUIApplication) -> [String: Double] {
        let label = app.staticTexts["vvterm.keyboardTest.diagnostics"].label
        return label.split(separator: " ").reduce(into: [:]) { result, token in
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return }
            result[String(parts[0])] = value
        }
    }

    func diagnosticMetric(
        _ name: String,
        in app: XCUIApplication
    ) throws -> Double {
        guard let value = diagnosticMetrics(in: app)[name] else {
            throw DiagnosticMetricError.missing(name)
        }
        return value
    }

    enum DiagnosticMetricError: Error {
        case missing(String)
    }
}
#endif

