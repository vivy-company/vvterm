//
//  SettingsWindowManager.swift
//  VVTerm
//
//  Centralized settings window presenter
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)

/// Wrapper view that observes language changes and applies locale environment
private struct LocalizedSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        let locale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
        SettingsView()
            .modifier(AppearanceModifier())
            .environment(\.locale, locale)
    }
}

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

        let settingsView = LocalizedSettingsView()
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
