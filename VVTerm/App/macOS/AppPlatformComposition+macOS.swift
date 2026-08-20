#if os(macOS)
import AppKit

@MainActor
struct AppPlatformComposition {
    let applicationIsActive: @MainActor @Sendable () -> Bool
    let lifecycleDependencies: AppLifecycleDependencies

    static func live(
        cloudKitManager: CloudKitManager,
        networkMonitor: NetworkMonitor,
        liveActivityManager _: LiveActivityManager
    ) -> Self {
        Self(
            applicationIsActive: {
                NSApplication.shared.isActive
            },
            lifecycleDependencies: AppLifecycleDependencies(
                subscribeToRemoteChanges: {
                    await cloudKitManager.subscribeToChanges()
                },
                refreshNetwork: {
                    networkMonitor.refreshCurrentPath()
                }
            )
        )
    }
}
#endif
