//
//  VivyTermApp.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

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

    // Welcome screen flag
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    // App language
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    // Terminal settings to watch for changes
    @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
    @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true

    var body: some Scene {
        WindowGroup {
            let appLocale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
            Group {
                #if os(iOS)
                iOSContentView()
                    .environmentObject(ghosttyApp)
                    .modifier(AppearanceModifier())
                    .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)") {
                        ghosttyApp.reloadConfig()
                    }
                    .sheet(isPresented: .init(
                        get: { !hasSeenWelcome },
                        set: { if !$0 { hasSeenWelcome = true } }
                    )) {
                        WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                            .interactiveDismissDisabled()
                    }
                #else
                ContentView()
                    .environmentObject(ghosttyApp)
                    .modifier(AppearanceModifier())
                    .task(id: "\(terminalFontName)\(terminalFontSize)\(terminalThemeName)\(terminalThemeNameLight)\(usePerAppearanceTheme)") {
                        ghosttyApp.reloadConfig()
                    }
                    .sheet(isPresented: .init(
                        get: { !hasSeenWelcome },
                        set: { if !$0 { hasSeenWelcome = true } }
                    )) {
                        WelcomeView(hasSeenWelcome: $hasSeenWelcome)
                            .interactiveDismissDisabled()
                    }
                #endif
            }
            .environment(\.locale, appLocale)
            .onAppear {
                AppLanguage.applySelection(appLanguage)
            }
            .onChange(of: appLanguage) { _, newValue in
                AppLanguage.applySelection(newValue)
            }
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
        NSApplication.shared.registerForRemoteNotifications()
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

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard SyncSettings.isEnabled else { return }
        Task {
            await ServerManager.shared.loadData()
        }
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
        application.registerForRemoteNotifications()

        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard SyncSettings.isEnabled else {
            completionHandler(.noData)
            return
        }

        Task {
            await ServerManager.shared.loadData()
            completionHandler(.newData)
        }
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
