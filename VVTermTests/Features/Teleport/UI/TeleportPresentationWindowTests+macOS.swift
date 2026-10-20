#if os(macOS)
import AppKit
import Testing
@testable import VVTerm

@MainActor
struct TeleportPresentationWindowTests {
    @Test
    func readerTracksItsOwnViewWhenItMovesBetweenWindows() {
        let source = TeleportPresentationWindow()
        let view = TeleportPresentationWindowReader.WindowView(presentationWindow: source)
        let firstWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)

        firstWindow.contentView = view
        #expect(source.value === firstWindow)
        secondWindow.contentView = view
        #expect(source.value === secondWindow)
        view.removeFromSuperview()
        #expect(source.value == nil)
    }
}
#endif
