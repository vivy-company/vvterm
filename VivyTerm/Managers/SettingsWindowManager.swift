//
//  SettingsWindowManager.swift
//  VivyTerm
//
//  Centralized settings window presenter
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var settingsWindow: NSWindow?

    private init() {}

    func show() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
            .modifier(AppearanceModifier())
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        // Create toolbar for unified style with subtitles
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setContentSize(NSSize(width: 800, height: 600))
        window.minSize = NSSize(width: 750, height: 500)

        window.center()
        window.makeKeyAndOrderFront(nil)

        settingsWindow = window
    }
}
#endif
