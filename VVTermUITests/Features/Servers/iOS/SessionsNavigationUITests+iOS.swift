#if os(iOS)
import XCTest
import UIKit

final class SessionsNavigationUITests: TerminalReconnectUITestCase {
    @MainActor
    func testExpandedSidebarSearchStaysInItsColumn() throws {
        let app = launchSessions()
        defer { app.terminate() }
        let workspace = app.buttons["vvterm.sidebar.workspace"]
        guard workspace.waitForExistence(timeout: 5), workspace.isHittable else {
            throw XCTSkip("This check needs an expanded sidebar.")
        }
        let list = app.descendants(matching: .any)["vvterm.serverList.list"].firstMatch
        let search = app.searchFields["Search servers"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(search.frame.minX, list.frame.minX)
        XCTAssertLessThanOrEqual(search.frame.maxX, list.frame.maxX)
        XCTAssertGreaterThanOrEqual(search.frame.minY, workspace.frame.maxY,
                                   "Sidebar search must stay below its toolbar, not across the bottom.")
    }

    @MainActor
    func testIPadSidebarWorkspaceAndToolbarActions() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad sidebar") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO"]
        app.launch()
        let mapsPrompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
            .containing(.staticText, identifier: "Allow widgets from “Maps” to use your location?").firstMatch
        if mapsPrompt.exists { mapsPrompt.buttons["Don’t Allow"].tap() }
        defer { app.terminate() }
        let workspace = app.buttons["vvterm.sidebar.workspace"]
        let settings = app.buttons["vvterm.serverList.settings"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        let addServer = app.buttons["vvterm.serverList.add"]
        XCTAssertTrue(addServer.isHittable)
        XCTAssertLessThan(settings.frame.maxX, addServer.frame.minX)
        XCTAssertGreaterThan(workspace.frame.minX, settings.frame.maxX)
        XCTAssertLessThan(workspace.frame.maxX, addServer.frame.minX)
        let actionGapCenter = (settings.frame.maxX + addServer.frame.minX) / 2
        XCTAssertEqual(workspace.frame.midX, actionGapCenter, accuracy: 8,
                       "Workspace selection must center between Settings and Add, including in a window.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Native iPad sidebar"
        shot.lifetime = .keepAlways
        add(shot)
        workspace.tap()
        let picker = app.navigationBars["Workspaces"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons.matching(identifier: "xmark").firstMatch.tap()
        settings.tap()
        XCTAssertTrue(app.buttons["vvterm.settings.close"].waitForExistence(timeout: 5))
        app.buttons["vvterm.settings.close"].tap()
        XCTAssertTrue(workspace.isHittable)
    }

    @MainActor
    func testSessionsOpenExactTabsAndKeepShells() throws {
        let app = launchSessions()
        defer { app.terminate() }
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        let rows = sessionRows(in: app)
        XCTAssertEqual(rows.count, 3)
        let firstID = rows.element(boundBy: 0).identifier
        let secondID = rows.element(boundBy: 1).identifier
        rows.element(boundBy: 0).tap()
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
        let first = try terminalSnapshot(in: diagnostics, app: app)
        openSessions(in: app)
        sessionRows(in: app).matching(identifier: secondID).firstMatch.tap()
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
        let second = try terminalSnapshot(in: diagnostics, app: app)
        XCTAssertNotEqual(first.shellId, second.shellId)
        openSessions(in: app)
        sessionRows(in: app).matching(identifier: firstID).firstMatch.tap()
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
        assertSameSession(as: first, diagnostics: diagnostics, app: app)
        openSessions(in: app)
        XCTAssertEqual(sessionRows(in: app).count, 3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Sessions grouped by server"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testClosingLastFilesTabDoesNotReappear() {
        assertLastFilesTabStaysClosed(usingSwipe: false)
    }

    @MainActor
    func testSwipingLastFilesTabDoesNotReappear() {
        assertLastFilesTabStaysClosed(usingSwipe: true)
    }

    @MainActor
    private func assertLastFilesTabStaysClosed(usingSwipe: Bool) {
        let app = launchSessions()
        defer { app.terminate() }
        let rows = sessionRows(in: app)
        XCTAssertEqual(rows.count, 3)
        let fileID = rows.element(boundBy: 2).identifier
        rows.element(boundBy: 2).tap()
        openSessions(in: app)
        let fileRow = sessionRows(in: app).matching(identifier: fileID).firstMatch
        if usingSwipe { fileRow.swipeLeft() } else { fileRow.press(forDuration: 1) }
        app.buttons["Close Tab"].tap()
        let confirm = app.buttons["vvterm.sessions.confirmRemoval"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(fileRow.exists, "Keep the row until deletion is confirmed")
        XCTAssertTrue(app.alerts["Close Tab"].exists)
        XCTAssertTrue(app.alerts["Close Tab"].buttons["Cancel"].exists)
        confirm.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: sessionRows(in: app))
        waitForExpectations(timeout: 5)
        let returned = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.buttons[fileID])
        returned.isInverted = true
        wait(for: [returned], timeout: 3)
        XCTAssertEqual(sessionRows(in: app).count, 2)
    }

    @MainActor
    func testCloseTabKeepsOtherSessionsAndFilesOpen() {
        let app = launchSessions()
        defer { app.terminate() }
        let rows = sessionRows(in: app)
        XCTAssertEqual(rows.count, 3)
        let secondID = rows.element(boundBy: 1).identifier
        let fileID = rows.element(boundBy: 2).identifier
        rows.element(boundBy: 0).press(forDuration: 1)
        app.buttons["Close Tab"].tap()
        let confirm = app.buttons["vvterm.sessions.confirmRemoval"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: sessionRows(in: app))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons[secondID].exists)
        XCTAssertTrue(app.buttons[fileID].exists)
    }

    @MainActor
    func testIPadSidebarKeepsSessionAcrossHideShow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad sidebar") }
        let app = launchSessions()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let list = app.descendants(matching: .any).matching(identifier: "vvterm.serverList.list").firstMatch
        XCTAssertLessThan(list.frame.width, app.frame.width * 0.6)
        sessionRows(in: app).element(boundBy: 0).tap()
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
        let original = try terminalSnapshot(in: diagnostics, app: app)
        let toggle = app.buttons["vvterm.sidebar.toggle"]
        for _ in 0..<2 {
            toggle.tap()
            XCTAssertFalse(list.isHittable)
            assertSameSession(as: original, diagnostics: diagnostics, app: app)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
            toggle.tap()
            XCTAssertTrue(list.isHittable)
            assertSameSession(as: original, diagnostics: diagnostics, app: app)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iPad sidebar and live terminal"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testFilesSessionOpensWithoutCreatingTerminalTab() {
        let app = launchSessions()
        defer { app.terminate() }
        let rows = sessionRows(in: app)
        let fileID = rows.element(boundBy: 2).identifier
        rows.element(boundBy: 2).tap()
        let files = app.segmentedControls.buttons.containing(.image, identifier: "folder").firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(files.isSelected)
        openSessions(in: app)
        XCTAssertEqual(sessionRows(in: app).count, 3)
        XCTAssertTrue(sessionRows(in: app).matching(identifier: fileID).firstMatch.isSelected)
    }

    @MainActor
    func testIPadSidebarSelectionFollowsSurfacePicker() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad sidebar") }
        let app = launchSessions()
        defer { app.terminate() }
        let fileID = sessionRows(in: app).element(boundBy: 2).identifier
        sessionRows(in: app).matching(identifier: fileID).firstMatch.tap()
        let fileRow = sessionRows(in: app).matching(identifier: fileID).firstMatch
        XCTAssertTrue(fileRow.isSelected)
        app.segmentedControls.buttons["chart.bar.xaxis"].tap()
        expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: fileRow)
        waitForExpectations(timeout: 5)
        app.segmentedControls.buttons.containing(.image, identifier: "folder").firstMatch.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: fileRow)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func launchSessions() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--vvterm-ui-test-terminal-reconnect-harness", "--vvterm-ui-test-sessions",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO", "-terminalTmuxEnabledDefault", "NO",
            "-terminalInputMode", "direct", "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO", "-security.lockOnBackground", "NO"]
        app.launch()
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        // Match the existing navigation fixture's simulator launch recovery.
        if !diagnostics.waitForExistence(timeout: 5), app.state == .runningForeground {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready", timeout: 45, app: app)
        XCTAssertTrue(sessionRows(in: app).firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func sessionRows(in app: XCUIApplication) -> XCUIElementQuery {
        let switcher = app.descendants(matching: .any).matching(identifier: "vvterm.sessions.switcher").firstMatch
        let container = switcher.exists ? switcher : app
        return container.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vvterm.sessions.tab."))
    }

    @MainActor
    func openSessions(in app: XCUIApplication) {
        app.buttons["vvterm.terminal.moreMenu"].tap()
        app.buttons["vvterm.terminal.sessions"].tap()
        XCTAssertTrue(sessionRows(in: app).firstMatch.waitForExistence(timeout: 5))
    }
}
#endif
