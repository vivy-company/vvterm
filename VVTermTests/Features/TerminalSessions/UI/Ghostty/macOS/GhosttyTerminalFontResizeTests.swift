#if os(macOS)
import AppKit
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalFontResizeTests {
    @Test
    func fontChangeReportsGridWithoutWindowResizeAndSchedulesRendering() throws {
        let app = GhosttyRuntime()
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: "/",
            ghosttyApp: try #require(app.app),
            appWrapper: app,
            useCustomIO: true
        )
        defer {
            terminal.cleanup()
            app.cleanup()
        }
        var reportedGrids: [(Int, Int)] = []
        terminal.onResize = { reportedGrids.append(($0, $1)) }
        terminal.layout()
        let original = try #require(terminal.terminalSize())
        let originalBounds = terminal.bounds
        reportedGrids.removeAll()
        terminal.needsRender = false

        let defaults = Ghostty.RuntimeConfiguration.defaultValue
        let configuration = Ghostty.RuntimeConfiguration(
            fontSelection: defaults.fontSelection,
            fontSize: 24,
            contentPadding: defaults.contentPadding,
            cursorStyleRawValue: defaults.cursorStyle.rawValue,
            cursorBlink: defaults.cursorBlink,
            optionAsAltModeRawValue: defaults.optionAsAltMode.rawValue,
            remoteClipboardPolicyRawValue: defaults.remoteClipboardPolicy.rawValue
        )
        app.applyConfiguration(configuration)

        let resized = try #require(terminal.terminalSize())
        #expect(terminal.bounds == originalBounds)
        #expect(resized.columns != original.columns || resized.rows != original.rows)
        #expect(reportedGrids.count == 1)
        #expect(reportedGrids.last?.0 == Int(resized.columns))
        #expect(reportedGrids.last?.1 == Int(resized.rows))
        #expect(terminal.needsRender)

        terminal.layout()
        terminal.forceRefresh()
        #expect(reportedGrids.count == 1)
    }
}
#endif
