#if os(macOS)
import AppKit
import SwiftUI

struct TeleportPresentationWindowReader: NSViewRepresentable {
    let presentationWindow: TeleportPresentationWindow

    func makeNSView(context: Context) -> WindowView {
        WindowView(presentationWindow: presentationWindow)
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.presentationWindow = presentationWindow
        presentationWindow.value = view.window
    }

    final class WindowView: NSView {
        var presentationWindow: TeleportPresentationWindow

        init(presentationWindow: TeleportPresentationWindow) {
            self.presentationWindow = presentationWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not available") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presentationWindow.value = window
        }
    }
}
#endif
