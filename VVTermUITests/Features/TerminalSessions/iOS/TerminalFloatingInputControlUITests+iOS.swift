#if os(iOS)
import XCTest

final class TerminalFloatingInputControlUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testKeyboardAccessoryVoiceUsesPanelAndFloatingVoiceStaysSeparate() {
        let app = launchFloatingControlHarness()
        app.buttons["vvterm.terminal.floating.keyboard"].tap()
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        let voice = app.buttons["vvterm.keyboard.accessory.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()
        let cancel = app.buttons["Cancel voice input"]
        let send = app.buttons["Send voice input"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(send.exists)
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.stopVoice"].exists)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        voice.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(send.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.return"].exists)

        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        let floatingVoice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(floatingVoice.waitForExistence(timeout: 5))
        floatingVoice.tap()
        XCTAssertTrue(app.buttons["vvterm.terminal.floating.stopVoice"].waitForExistence(timeout: 5))
        XCTAssertFalse(send.exists)
    }

    @MainActor
    func testCompactControlCanReachLandscapeRightAndBottomEdges() {
        let app = launchFloatingControlHarness()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { app.frame.width > app.frame.height })
        let rightX = voice.frame.midX
        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ))
        XCTAssertTrue(waitUntil { abs(voice.frame.midY - app.frame.midY) < 45 })
        // Use the visible control's side limit so the gesture does not request hiding.
        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(
                    dx: (rightX - app.frame.minX) / app.frame.width,
                    dy: (app.frame.height - 40) / app.frame.height
                )
            ))
        XCTAssertTrue(waitUntil {
            voice.exists && app.frame.maxY - voice.frame.maxY <= 26
                && app.frame.maxX - voice.frame.maxX < 100
        }, "The control has an extra inset at the right or bottom edge.")
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.stopVoice"].exists)
    }

    @MainActor
    func testCompactControlMovesFreelyWithoutStartingVoiceAndRestoresKeyboard() {
        let app = launchFloatingControlHarness()
        let control = app.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        let keyboard = app.buttons["vvterm.terminal.floating.keyboard"]

        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertEqual(control.value as? String, "Compact Buttons")
        XCTAssertTrue(voice.exists)
        XCTAssertTrue(keyboard.exists)

        let initialMidX = control.frame.midX
        let target = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.52, dy: 0.42)
        )
        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: target
            )

        XCTAssertTrue(
            waitUntil { abs(control.frame.midX - app.frame.midX) < 45 },
            "The control did not keep the free horizontal position. "
                + "Initial x: \(initialMidX), current x: \(control.frame.midX), "
                + "screen x: \(app.frame.midX)."
        )
        XCTAssertLessThan(control.frame.midX, initialMidX)
        XCTAssertGreaterThan(control.frame.midX, app.frame.minX + 90)
        XCTAssertLessThan(control.frame.midX, app.frame.maxX - 90)
        XCTAssertTrue(voice.exists, "Dragging started Voice input.")
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.stopVoice"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(
            waitUntil {
                control.isHittable
                    && app.frame.insetBy(dx: 11, dy: 11).contains(control.frame)
            },
            "The control left the screen after rotation. "
                + "Control: \(control.frame), screen: \(app.frame)."
        )

        keyboard.tap()
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(
            for: diagnostics,
            labelContaining: "userHidden=false",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        XCTAssertTrue(control.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSecondaryActionCanMoveControlWithoutOpeningKeyboard() {
        let app = launchFloatingControlHarness()
        let control = app.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        let keyboard = app.buttons["vvterm.terminal.floating.keyboard"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists)

        let initialMidX = control.frame.midX
        keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)
                )
            )

        XCTAssertTrue(
            waitUntil { abs(control.frame.midX - app.frame.midX) < 50 },
            "Dragging the secondary action did not move the control."
        )
        XCTAssertLessThan(control.frame.midX, initialMidX)
        XCTAssertTrue(keyboard.exists, "Dragging performed the Keyboard action.")
        XCTAssertTrue(
            app.staticTexts["vvterm.keyboardTest.diagnostics"]
                .label.contains("userHidden=true")
        )
    }

    @MainActor
    func testConfiguredSecondaryActionCanMoveRadialControlWithoutSendingInput() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-many-actions",
            ]
        )
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        let escape = app.buttons["vvterm.terminal.floating.system.escape"]
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(escape.waitForExistence(timeout: 5))

        let initialVoiceMidX = voice.frame.midX
        escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                )
            )

        XCTAssertTrue(
            waitUntil { voice.frame.midX < initialVoiceMidX - 40 },
            "Dragging a configured secondary action did not move the Radial control."
        )
        XCTAssertTrue(escape.exists, "Dragging performed the Escape action.")
        XCTAssertFalse(
            waitUntil(timeout: 0.5) {
                !diagnostics.label.contains("inputHex=none")
            },
            "Dragging sent terminal input. Diagnostics: \(diagnostics.label)"
        )
    }

    @MainActor
    func testRepeatableSecondaryActionCanMoveRadialControlWithoutRepeating() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-many-actions",
            ]
        )
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        let backspace = app.buttons["vvterm.terminal.floating.system.backspace"]
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(backspace.waitForExistence(timeout: 5))

        let initialVoiceMidX = voice.frame.midX
        backspace.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                )
            )

        XCTAssertTrue(
            waitUntil { voice.frame.midX < initialVoiceMidX - 40 },
            "Dragging Backspace did not move the Radial control."
        )
        XCTAssertFalse(
            waitUntil(timeout: 0.5) {
                diagnosticInteger(named: "backspaceInputs", in: diagnostics) > 0
            },
            "Dragging Backspace sent repeat input. Diagnostics: \(diagnostics.label)"
        )
    }

    @MainActor
    func testVoiceChangesToStopReturnAndIdle() {
        let app = launchFloatingControlHarness()
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        let idleMainFrame = voice.frame

        voice.tap()
        let stop = app.buttons["vvterm.terminal.floating.stopVoice"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        assertSameMainButtonFrame(stop.frame, as: idleMainFrame)
        XCTAssertTrue(app.buttons["vvterm.terminal.floating.cancelVoice"].exists)
        let status = app.descendants(matching: .any)[
            "vvterm.terminal.floating.voiceStatus"
        ]
        let control = app.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(app.frame.contains(status.frame))
        XCTAssertFalse(status.frame.intersects(control.frame))

        stop.tap()
        let sendReturn = app.buttons["vvterm.terminal.floating.return"]
        XCTAssertTrue(sendReturn.waitForExistence(timeout: 5))
        assertSameMainButtonFrame(sendReturn.frame, as: idleMainFrame)
        sendReturn.tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        assertSameMainButtonFrame(voice.frame, as: idleMainFrame)

        voice.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        let recordingMainFrame = stop.frame
        app.buttons["vvterm.terminal.floating.cancelVoice"].tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        assertSameMainButtonFrame(voice.frame, as: recordingMainFrame)
    }

    @MainActor
    func testEditingActionReplacesPendingReturnWithDictate() {
        let app = launchFloatingControlHarness()
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        let stop = app.buttons["vvterm.terminal.floating.stopVoice"]
        let sendReturn = app.buttons["vvterm.terminal.floating.return"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))

        let editingActionIdentifiers = [
            "vvterm.terminal.floating.system.backspace",
            "vvterm.terminal.floating.system.escape",
        ]
        for identifier in editingActionIdentifiers {
            voice.tap()
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            stop.tap()
            XCTAssertTrue(sendReturn.waitForExistence(timeout: 5))

            let editingAction = app.buttons[identifier]
            XCTAssertTrue(editingAction.waitForExistence(timeout: 5))
            editingAction.tap()

            XCTAssertTrue(voice.waitForExistence(timeout: 5))
            XCTAssertFalse(sendReturn.exists)
        }
    }

    @MainActor
    func testControlHidesAtSideAndEdgeTabRestoresIt() {
        let app = launchFloatingControlHarness()
        let control = app.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.exists)

        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.001, dy: 0.55)
                )
            )

        XCTAssertTrue(control.waitForNonExistence(timeout: 5))
        let edgeHandle = app.buttons["vvterm.terminal.floating.edgeHandle"]
        XCTAssertTrue(edgeHandle.waitForExistence(timeout: 5))
        XCTAssertLessThan(edgeHandle.frame.midX, app.frame.midX)
        XCTAssertEqual(edgeHandle.frame.width, 44, accuracy: 1)
        XCTAssertEqual(edgeHandle.frame.height, 52, accuracy: 1)
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.stopVoice"].exists)

        edgeHandle.tap()

        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(edgeHandle.waitForNonExistence(timeout: 5))
        XCTAssertLessThan(
            control.frame.midX,
            app.frame.midX,
            "The restored control did not stay near the hidden side."
        )
    }

    @MainActor
    func testEdgeTabCanMoveVerticallyAndDragBackIntoView() {
        let app = launchFloatingControlHarness()
        let control = app.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))

        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.001, dy: 0.45)
                )
            )

        let edgeHandle = app.buttons["vvterm.terminal.floating.edgeHandle"]
        XCTAssertTrue(edgeHandle.waitForExistence(timeout: 5))
        let initialMidY = edgeHandle.frame.midY
        edgeHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.02, dy: 0.72)
                )
            )

        XCTAssertTrue(edgeHandle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntil { edgeHandle.frame.midY > initialMidY + 60 },
            "The edge tab did not keep its new vertical position."
        )
        XCTAssertTrue(control.waitForNonExistence(timeout: 1))

        edgeHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.3, dy: 0.62)
                )
            )

        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(edgeHandle.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(control.frame.midX, app.frame.minX + 45)
    }

    @MainActor
    func testRecordingControlMovesButCannotBeHiddenAtSide() {
        let app = launchFloatingControlHarness()
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()

        let stop = app.buttons["vvterm.terminal.floating.stopVoice"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        let initialMidX = stop.frame.midX
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.001, dy: 0.55)
                )
            )

        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntil { stop.frame.midX < initialMidX - 40 },
            "The recording control did not move."
        )
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.edgeHandle"].exists)
    }

    @MainActor
    func testTranscribingControlMovesButCannotBeHiddenAtSide() {
        let app = launchFloatingControlHarness(
            arguments: ["--vvterm-ui-test-floating-slow-transcription"]
        )
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()

        let stop = app.buttons["vvterm.terminal.floating.stopVoice"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        let progress = app.buttons["vvterm.terminal.floating.voiceProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let initialMidX = progress.frame.midX
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)
                )
            )

        XCTAssertTrue(
            waitUntil { progress.exists && progress.frame.midX < initialMidX - 40 },
            "The transcribing control did not move."
        )
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.edgeHandle"].exists)
    }

    @MainActor
    func testPrimaryControlCanReachBottomRightScreenCorner() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-bottom-right",
            ]
        )
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))

        XCTAssertEqual(app.frame.maxX - voice.frame.maxX, 24, accuracy: 1)
        XCTAssertEqual(app.frame.maxY - voice.frame.maxY, 24, accuracy: 1)

        let secondaryActions = [
            app.buttons["vvterm.terminal.floating.keyboard"],
            app.buttons["vvterm.terminal.floating.system.escape"],
            app.buttons["vvterm.terminal.floating.system.tab"],
        ]
        for action in secondaryActions {
            XCTAssertTrue(action.exists)
            XCTAssertTrue(app.frame.contains(action.frame))
        }
    }

    @MainActor
    func testOffFreeFallbackAndProRadialStyles() {
        let offApp = launchFloatingControlHarness(
            arguments: ["--vvterm-ui-test-floating-style-off"]
        )
        XCTAssertTrue(
            offApp.descendants(matching: .any)[
                "vvterm.terminal.floatingInputControl"
            ].waitForNonExistence(timeout: 2)
        )

        let freeApp = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-free",
            ]
        )
        let freeControl = freeApp.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        XCTAssertTrue(freeControl.waitForExistence(timeout: 5))
        XCTAssertEqual(freeControl.value as? String, "Compact Buttons")
        XCTAssertTrue(
            freeApp.buttons["vvterm.terminal.floating.system.backspace"].exists
        )
        XCTAssertTrue(
            freeApp.buttons["vvterm.terminal.floating.system.escape"].exists
        )
        XCTAssertTrue(freeApp.buttons["vvterm.terminal.floating.keyboard"].exists)
        XCTAssertFalse(
            freeApp.buttons["vvterm.terminal.floating.system.tab"].exists
        )

        let proApp = launchFloatingControlHarness(
            arguments: ["--vvterm-ui-test-floating-style-radial"]
        )
        let proControl = proApp.descendants(matching: .any)[
            "vvterm.terminal.floatingInputControl"
        ]
        XCTAssertTrue(proControl.waitForExistence(timeout: 5))
        XCTAssertEqual(proControl.value as? String, "Radial Control")

        let escape = proApp.buttons["vvterm.terminal.floating.system.escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        let voice = proApp.buttons["vvterm.terminal.floating.voiceInput"]
        let keyboard = proApp.buttons["vvterm.terminal.floating.keyboard"]
        let tab = proApp.buttons["vvterm.terminal.floating.system.tab"]
        XCTAssertTrue(voice.exists)
        XCTAssertTrue(keyboard.exists)
        XCTAssertTrue(tab.exists)
        XCTAssertGreaterThan(voice.frame.width, escape.frame.width * 1.4)
        for action in [keyboard, escape, tab] {
            XCTAssertTrue(
                proApp.frame.contains(action.frame),
                "Radial action left the screen: \(action.identifier), \(action.frame)."
            )
        }
        escape.tap()
        wait(
            for: proApp.staticTexts["vvterm.keyboardTest.diagnostics"],
            labelContaining: "inputHex=1b",
            timeout: 5,
            diagnostics: diagnosticsText(in: proApp)
        )
    }

    @MainActor
    func testRadialControlShowsSixSystemActionsAroundPrimaryAction() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-many-actions",
            ]
        )
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))

        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                )
            )
        XCTAssertTrue(
            waitUntil {
                abs(voice.frame.midX - app.frame.midX) < 20
                    && abs(voice.frame.midY - app.frame.midY) < 20
            },
            "The main Radial button did not move to open space. "
                + "Button: \(voice.frame), screen: \(app.frame)."
        )
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.stopVoice"].exists)

        let actionIDs = [
            "backspace",
            "escape",
            "tab",
            "arrowUp",
            "arrowDown",
            "arrowLeft",
        ]
        for actionID in actionIDs {
            XCTAssertTrue(
                app.buttons["vvterm.terminal.floating.system.\(actionID)"].exists,
                "Missing radial action: \(actionID)"
            )
        }
        XCTAssertTrue(app.buttons["vvterm.terminal.floating.keyboard"].exists)

        let systemFrames = actionIDs.map {
            app.buttons["vvterm.terminal.floating.system.\($0)"].frame
        }
        XCTAssertTrue(systemFrames.contains { $0.midX < voice.frame.midX })
        XCTAssertTrue(systemFrames.contains { $0.midX > voice.frame.midX })
        XCTAssertTrue(systemFrames.contains { $0.midY < voice.frame.midY })
        XCTAssertTrue(systemFrames.contains { $0.midY > voice.frame.midY })
    }

    @MainActor
    func testRadialMainMovesNearSideWhileEveryActionStaysVisible() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-many-actions",
            ]
        )
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))

        voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.14, dy: 0.35)
                )
            )

        XCTAssertTrue(
            waitUntil { voice.frame.midX < app.frame.minX + 80 },
            "The main Radial button did not reach the side. "
                + "Button: \(voice.frame), screen: \(app.frame)."
        )
        XCTAssertFalse(app.buttons["vvterm.terminal.floating.stopVoice"].exists)

        let actionIDs = [
            "vvterm.terminal.floating.keyboard",
            "vvterm.terminal.floating.system.backspace",
            "vvterm.terminal.floating.system.escape",
            "vvterm.terminal.floating.system.tab",
            "vvterm.terminal.floating.system.arrowUp",
            "vvterm.terminal.floating.system.arrowDown",
            "vvterm.terminal.floating.system.arrowLeft",
        ]
        for actionID in actionIDs {
            let action = app.buttons[actionID]
            XCTAssertTrue(action.exists, "Missing Radial action: \(actionID)")
            XCTAssertTrue(
                app.frame.contains(action.frame),
                "Radial action left the screen: \(actionID), \(action.frame)."
            )
        }
    }

    @MainActor
    func testSecondarySystemActionRepeatsWhenHeldInsideDraggableGroup() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-many-actions",
            ]
        )
        let backspace = app.buttons["vvterm.terminal.floating.system.backspace"]
        let voice = app.buttons["vvterm.terminal.floating.voiceInput"]
        XCTAssertTrue(backspace.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.exists)
        XCTAssertGreaterThan(voice.frame.width, backspace.frame.width * 1.4)

        backspace.press(forDuration: 0.65)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        XCTAssertTrue(
            waitUntil {
                diagnosticInteger(named: "backspaceInputs", in: diagnostics) >= 2
            },
            "Holding Backspace did not repeat. Diagnostics: \(diagnostics.label)"
        )
    }

    @MainActor
    func testPrimarySystemActionStillRepeatsWhenHeld() {
        let app = launchFloatingControlHarness(
            arguments: [
                "--vvterm-ui-test-floating-style-radial",
                "--vvterm-ui-test-floating-primary-backspace",
            ]
        )
        let backspace = app.buttons["vvterm.terminal.floating.system.backspace"]
        XCTAssertTrue(backspace.waitForExistence(timeout: 5))

        backspace.press(forDuration: 0.65)

        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        XCTAssertTrue(
            waitUntil {
                diagnosticInteger(named: "backspaceInputs", in: diagnostics) >= 2
            },
            "Holding the primary Backspace action did not repeat. Diagnostics: "
                + diagnostics.label
        )
    }

    @MainActor
    private func launchFloatingControlHarness(
        arguments: [String] = []
    ) -> XCUIApplication {
        let app = launchKeyboardHarness(
            simulatesKeyboardFrames: true,
            floatingControlArguments: arguments
        )
        let terminal = waitForTerminal(in: app)
        terminal.tap()
        app.buttons["vvterm.keyboardTest.geometry.docked"].tap()
        app.buttons["vvterm.keyboardTest.hideViaToolbar"].tap()
        wait(
            for: app.staticTexts["vvterm.keyboardTest.diagnostics"],
            labelContaining: "userHidden=true",
            timeout: 5,
            diagnostics: diagnosticsText(in: app)
        )
        return app
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    @MainActor
    private func diagnosticInteger(named name: String, in element: XCUIElement) -> Int {
        let prefix = "\(name)="
        guard let token = element.label.split(separator: " ").first(where: {
            $0.hasPrefix(prefix)
        }) else {
            return 0
        }
        return Int(token.dropFirst(prefix.count)) ?? 0
    }

    private func assertSameMainButtonFrame(
        _ frame: CGRect,
        as expectedFrame: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(frame.midX, expectedFrame.midX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.midY, expectedFrame.midY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.width, expectedFrame.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.height, expectedFrame.height, accuracy: 1, file: file, line: line)
    }
}
#endif
