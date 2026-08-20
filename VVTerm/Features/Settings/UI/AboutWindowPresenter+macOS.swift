#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol AboutWindowHandling: AnyObject {
    func presentAboutWindow()
}

extension NSWindow: AboutWindowHandling {
    func presentAboutWindow() {
        makeKeyAndOrderFront(nil)
    }
}

/// Owns the macOS About window and reuses it after it is closed.
@MainActor
final class AboutWindowPresenter {
    typealias MakeWindow = @MainActor () -> any AboutWindowHandling
    typealias ActivateApplication = @MainActor () -> Void

    private let makeWindow: MakeWindow
    private let activateApplication: ActivateApplication
    private var aboutWindow: (any AboutWindowHandling)?

    init() {
        makeWindow = {
            Self.makeAboutWindow()
        }
        activateApplication = {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    init(
        makeWindow: @escaping MakeWindow,
        activateApplication: @escaping ActivateApplication
    ) {
        self.makeWindow = makeWindow
        self.activateApplication = activateApplication
    }

    func show() {
        let window: any AboutWindowHandling
        if let aboutWindow {
            window = aboutWindow
        } else {
            let newWindow = makeWindow()
            aboutWindow = newWindow
            window = newWindow
        }

        window.presentAboutWindow()
        activateApplication()
    }

    private static func makeAboutWindow() -> NSWindow {
        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: hostingView.fittingSize.width,
                height: hostingView.fittingSize.height
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "About VVTerm")
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}
#endif
