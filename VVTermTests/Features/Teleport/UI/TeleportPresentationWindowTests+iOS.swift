#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TeleportPresentationWindowTests {
    @Test
    func readerTracksItsOwnViewWhenItMovesBetweenWindows() {
        let source = TeleportPresentationWindow()
        let view = TeleportPresentationWindowReader.WindowView(presentationWindow: source)
        let firstWindow = UIWindow(frame: .zero)
        let secondWindow = UIWindow(frame: .zero)

        firstWindow.addSubview(view)
        #expect(source.value === firstWindow)
        secondWindow.addSubview(view)
        #expect(source.value === secondWindow)
        view.removeFromSuperview()
        #expect(source.value == nil)
    }
}
#endif
