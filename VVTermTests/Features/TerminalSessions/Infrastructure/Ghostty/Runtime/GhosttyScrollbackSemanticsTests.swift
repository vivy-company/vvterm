import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyScrollbackSemanticsTests {
    @Test
    func csiTwoJPreservesHistoryAndCsiThreeJErasesIt() throws {
        let app = GhosttyRuntime()
        let appHandle = try #require(app.app)
        let terminal: GhosttyTerminalView
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "scrollback-semantics",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "scrollback-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "scrollback-semantics",
            useCustomIO: true
        )
        #endif
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surface = try #require(terminal.surface)
        let cSurface = try #require(surface.unsafeCValue)
        let rowCount = max(Int(surface.terminalSize()?.rows ?? 24), 4)
        let oldestMarker = "__VVTERM_OLDEST_SCROLLBACK_MARKER__"
        let lines = (0..<(rowCount + 8)).map { index in
            index == 0 ? oldestMarker : "vvterm-scrollback-line-\(index)"
        }
        surface.feedText(lines.joined(separator: "\r\n") + "\r\n")

        #expect(!terminalText(cSurface, region: GHOSTTY_POINT_VIEWPORT).contains(oldestMarker))
        #expect(terminalText(cSurface, region: GHOSTTY_POINT_SCREEN).contains(oldestMarker))

        surface.feedText("\u{1B}[2J")
        #expect(terminalText(cSurface, region: GHOSTTY_POINT_SCREEN).contains(oldestMarker))

        surface.feedText("\u{1B}[3J")
        #expect(!terminalText(cSurface, region: GHOSTTY_POINT_SCREEN).contains(oldestMarker))
    }

    private func terminalText(
        _ surface: ghostty_surface_t,
        region: ghostty_point_tag_e
    ) -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: region,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: region,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else {
            Issue.record("Ghostty failed to read terminal text")
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let rawText = text.text else { return "" }

        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(rawText).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }
}
