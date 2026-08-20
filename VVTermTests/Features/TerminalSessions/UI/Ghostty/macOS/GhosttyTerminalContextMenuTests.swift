#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalContextMenuTests {
    @Test
    func uncapturedRightClickFallsBackToNativeContextMenu() throws {
        let app = GhosttyRuntime()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "context-menu-uncaptured",
            useCustomIO: true
        )
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let rightClick = try mouseEvent(type: .rightMouseDown)

        #expect(terminal.surface?.mouseCaptured == false)
        #expect(terminal.inputHandler.handleRightMouseDown(with: rightClick) == false)
        #expect(terminal.menu(for: rightClick) != nil)
    }

    @Test
    func capturedRightClickReportsToTerminalAndBlocksControlClickMenu() async throws {
        let app = GhosttyRuntime()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "context-menu-captured",
            useCustomIO: true
        )
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        var reportedData = Data()
        terminal.writeCallback = { data in
            reportedData.append(data)
        }
        terminal.setupWriteCallback()
        terminal.feedData(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))

        let surface = try #require(terminal.surface)
        #expect(surface.mouseCaptured)

        let mouseMoved = try mouseEvent(type: .mouseMoved)
        terminal.inputHandler.handleMouseMoved(
            with: mouseMoved,
            viewFrame: terminal.bounds,
            convertPoint: { point, _ in point }
        )
        reportedData.removeAll(keepingCapacity: true)

        let rightClick = try mouseEvent(type: .rightMouseDown)
        terminal.rightMouseDown(with: rightClick)
        terminal.forceRefresh()
        await Task.yield()
        try assertRightMouseReport(reportedData, actionTerminator: 0x4D)
        let pressReport = reportedData

        let controlClick = try mouseEvent(type: .leftMouseDown, modifiers: .control)
        #expect(terminal.menu(for: controlClick) == nil)

        reportedData.removeAll(keepingCapacity: true)
        let rightMouseUp = try mouseEvent(type: .rightMouseUp)
        terminal.rightMouseUp(with: rightMouseUp)
        terminal.forceRefresh()
        await Task.yield()
        try assertRightMouseReport(reportedData, actionTerminator: 0x6D)

        var expectedReleaseReport = pressReport
        let terminatorIndex = expectedReleaseReport.index(
            before: expectedReleaseReport.endIndex
        )
        expectedReleaseReport[terminatorIndex] = 0x6D
        #expect(reportedData == expectedReleaseReport)
    }

    private func assertRightMouseReport(
        _ data: Data,
        actionTerminator: UInt8
    ) throws {
        let report = try #require(String(data: data, encoding: .utf8))
        try #require(report.hasPrefix("\u{1B}[<2;"))
        try #require(report.utf8.last == actionTerminator)

        let fields = report.dropFirst(3).dropLast().split(separator: ";")
        try #require(fields.count == 3)
        #expect(fields.first == "2")

        let coordinates = fields.dropFirst().compactMap { Int($0) }
        #expect(coordinates.count == 2)
        #expect(coordinates.allSatisfy { $0 > 0 })
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: 40, y: 40),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
    }
}
#endif
