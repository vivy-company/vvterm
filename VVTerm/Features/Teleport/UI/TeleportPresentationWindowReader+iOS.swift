#if os(iOS)
import SwiftUI
import UIKit

struct TeleportPresentationWindowReader: UIViewRepresentable {
    let presentationWindow: TeleportPresentationWindow

    func makeUIView(context: Context) -> WindowView {
        WindowView(presentationWindow: presentationWindow)
    }

    func updateUIView(_ view: WindowView, context: Context) {
        view.presentationWindow = presentationWindow
        presentationWindow.value = view.window
    }

    final class WindowView: UIView {
        var presentationWindow: TeleportPresentationWindow

        init(presentationWindow: TeleportPresentationWindow) {
            self.presentationWindow = presentationWindow
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not available") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            presentationWindow.value = window
        }
    }
}
#endif
