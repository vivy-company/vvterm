//
//  VivyTermApp.swift
//  VivyTerm
//

import SwiftUI

// MARK: - Notification Names

extension Notification.Name {
    static let newTerminalTab = Notification.Name("newTerminalTab")
    static let closeTerminalPane = Notification.Name("closeTerminalPane")
}

@main
struct VivyTermApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if os(iOS)
    @StateObject private var ghosttyApp = Ghostty.App(autoStart: false)
    #else
    @StateObject private var ghosttyApp = Ghostty.App()
    #endif

    // Terminal settings to watch for changes
    @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
    @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            iOSContentView()
                .environmentObject(ghosttyApp)
                .modifier(AppearanceModifier())
                .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)") {
                    ghosttyApp.reloadConfig()
                }
            #else
            ContentView()
                .environmentObject(ghosttyApp)
                .modifier(AppearanceModifier())
                .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)") {
                    ghosttyApp.reloadConfig()
                }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About VVTerm") {
                    AboutWindowController.shared.show()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    // Open new tab handled by focused value
                    NotificationCenter.default.post(name: .newTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTerminalPane, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    SettingsWindowManager.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .windowArrangement) {
                Button("Previous Tab") {
                    ConnectionSessionManager.shared.selectPreviousSession()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Tab") {
                    ConnectionSessionManager.shared.selectNextSession()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            }

            // Split commands (Pro feature)
            SplitCommands()
        }
        #endif
    }
}

// MARK: - macOS App Delegate

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Subscribe to CloudKit changes
        Task {
            await CloudKitManager.shared.subscribeToChanges()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close all connections synchronously to ensure cleanup before exit
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await ConnectionSessionManager.shared.disconnectAll()
            semaphore.signal()
        }
        // Wait up to 2 seconds for cleanup
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in menu bar
    }
}
#else
// MARK: - iOS App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Subscribe to CloudKit changes
        Task {
            await CloudKitManager.shared.subscribeToChanges()
        }

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Close all connections synchronously to ensure cleanup before exit
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            ConnectionSessionManager.shared.disconnectAll()
            semaphore.signal()
        }
        // Wait up to 2 seconds for cleanup
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // Handle app going to background - close connections to save resources
    func applicationDidEnterBackground(_ application: UIApplication) {
        Task {
            ConnectionSessionManager.shared.disconnectAll()
        }
    }
}
#endif
