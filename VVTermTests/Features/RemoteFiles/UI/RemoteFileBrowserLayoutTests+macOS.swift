#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import VVTerm

@MainActor
final class RemoteFileBrowserLayoutTests: XCTestCase {
    func testNativeSurfacesFollowAppearance() {
        let screen = makeScreen()
        XCTAssertEqual(screen.chromeSurfaceColor, Color(nsColor: .windowBackgroundColor))
        XCTAssertEqual(screen.raisedSurfaceColor, Color(nsColor: .controlBackgroundColor))
    }

    func testTableRespectsToolbarOnFirstLayoutAndAfterUpdates() async throws {
        let screen = makeScreen()
        let host = NSHostingView(rootView: screen.browserContent(screen.snapshot))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "RemoteFileBrowserLayoutTests")
        window.toolbarStyle = .unified
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendant(of: NSTableView.self, in: host))
        XCTAssertFalse(table.usesAlternatingRowBackgroundColors, "Empty table space must not draw file-like stripes")
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let initialFrame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertLessThanOrEqual(initialFrame.maxY, window.contentLayoutRect.maxY + 1)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let updatedFrame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertEqual(initialFrame.maxY, updatedFrame.maxY, accuracy: 1)
        XCTAssertEqual(initialFrame.height, updatedFrame.height, accuracy: 1)
    }

    private func makeScreen() -> RemoteFileBrowserScreen<EmptyView> {
        let server = Server(workspaceId: UUID(), name: "Test", host: "example.invalid", username: "test")
        let defaults = UserDefaults(suiteName: "RemoteFileBrowserLayoutTests.\(UUID().uuidString)")!
        return RemoteFileBrowserScreen(
            browser: RemoteFileBrowserStore(defaults: defaults),
            server: server,
            fileTab: RemoteFileTab(serverId: server.id, seedPath: "/"),
            connectionActions: { EmptyView() }
        )
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }
}
#endif
