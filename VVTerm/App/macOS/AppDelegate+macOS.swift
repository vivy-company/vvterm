#if os(macOS)
import AppKit
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20
    private weak var tabManager: TerminalTabManager?
    private weak var serverManager: ServerManager?
    private weak var appLockManager: AppLockManager?
    private var lifecycleDependencies: AppLifecycleDependencies?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "Lifecycle"
    )

    func configure(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        appLockManager: AppLockManager,
        lifecycleDependencies: AppLifecycleDependencies
    ) {
        if let currentManager = self.tabManager {
            precondition(currentManager === tabManager, "AppDelegate received a different terminal manager")
        }
        if let currentManager = self.serverManager {
            precondition(currentManager === serverManager, "AppDelegate received a different server manager")
        }
        if let currentManager = self.appLockManager {
            precondition(currentManager === appLockManager, "AppDelegate received a different app lock manager")
        }
        self.tabManager = tabManager
        self.serverManager = serverManager
        self.appLockManager = appLockManager
        self.lifecycleDependencies = lifecycleDependencies
    }

    private var configuredTabManager: TerminalTabManager {
        guard let tabManager else {
            preconditionFailure("AppDelegate must be configured with a terminal manager")
        }
        return tabManager
    }

    private var configuredServerManager: ServerManager {
        guard let serverManager else {
            preconditionFailure("AppDelegate must be configured with a server manager")
        }
        return serverManager
    }

    private var configuredAppLockManager: AppLockManager {
        guard let appLockManager else {
            preconditionFailure("AppDelegate must be configured with an app lock manager")
        }
        return appLockManager
    }

    private var configuredLifecycleDependencies: AppLifecycleDependencies {
        guard let lifecycleDependencies else {
            preconditionFailure("AppDelegate must be configured with lifecycle dependencies")
        }
        return lifecycleDependencies
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let subscribeToRemoteChanges = configuredLifecycleDependencies.subscribeToRemoteChanges
        Task {
            await subscribeToRemoteChanges()
        }
        NSApplication.shared.registerForRemoteNotifications()

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        logger.info(
            "Application became active monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
        )
        configuredLifecycleDependencies.refreshNetwork()
        configuredTabManager.reconnectCoordinator.receiveMacRecoverySignal(.applicationActivated)
        guard SyncSettings.isEnabled else { return }

        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else { return }
        lastForegroundSyncAt = now

        Task {
            await configuredServerManager.loadData()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        logger.info("Application resigned active")
        Task { @MainActor in
            configuredAppLockManager.lockIfNeededForBackground()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let cleanupTask = configuredTabManager.beginApplicationTermination()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await cleanupTask.value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard SyncSettings.isEnabled else { return }
        Task {
            await configuredServerManager.loadData()
        }
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        logger.info(
            "Workspace will sleep monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
        )
        configuredTabManager.reconnectCoordinator.receiveMacRecoverySignal(.sleep)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        logger.info(
            "Workspace did wake monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
        )
        refreshNetworkAndHandleWake()
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        logger.info(
            "Screens did sleep monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
        )
        configuredTabManager.reconnectCoordinator.receiveMacRecoverySignal(.sleep)
    }

    @objc private func screensDidWake(_ notification: Notification) {
        logger.info(
            "Screens did wake monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
        )
        refreshNetworkAndHandleWake()
    }

    private func refreshNetworkAndHandleWake() {
        configuredLifecycleDependencies.refreshNetwork()
        configuredTabManager.reconnectCoordinator.receiveMacRecoverySignal(.wake)
    }
}
#endif
