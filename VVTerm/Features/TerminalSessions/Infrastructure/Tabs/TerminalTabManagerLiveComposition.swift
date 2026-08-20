import Combine
import Foundation

@MainActor
enum TerminalTabManagerLiveComposition {
    private static let persistenceKey = "terminalTabsSnapshot.v1"

    static func makeManager(
        defaults: UserDefaults,
        sshClientFactory: SSHClientFactory,
        networkMonitor: NetworkMonitor,
        appLockManager: AppLockManager,
        serverManager: ServerManager,
        engagementTracker: EngagementTracker,
        analyticsTracker: AnalyticsTracker,
        liveActivityManager: LiveActivityManager,
        remoteMosh: any TerminalRemoteMoshServicing,
        remoteTmux: any TerminalRemoteTmuxServicing,
        eternalTerminalResumeStore: any EternalTerminalResumeStoring,
        moshResumeStore: any MoshResumeStoring,
        terminalSurfaceStore: any TerminalSurfaceStoring,
        deviceID: String,
        themeStyle: @escaping @MainActor () -> RemoteTmuxThemeStyle,
        applicationIsActive: @escaping @MainActor @Sendable () -> Bool
    ) -> TerminalTabManager {
        let tmuxConfiguration = TerminalTmuxSessionLiveComposition.makeConfiguration(
            defaults: defaults,
            serverManager: serverManager,
            deviceID: deviceID,
            themeStyle: themeStyle
        )
        let dependencies = TerminalTabManagerDependencies(
            sshClientFactory: sshClientFactory,
            networkReadiness: TerminalNetworkReadinessSource(
                initial: TerminalNetworkReadiness(networkMonitor.readiness),
                updates: networkMonitor.$snapshot
                    .map { TerminalNetworkReadiness($0.readiness) }
                    .removeDuplicates()
                    .eraseToAnyPublisher()
            ),
            applicationIsActive: applicationIsActive,
            appLock: TerminalAppLockSource(
                initialIsLocked: appLockManager.isAppLocked,
                updates: appLockManager.$lockState
                    .map(\.isLocked)
                    .removeDuplicates()
                    .eraseToAnyPublisher()
            ),
            effects: TerminalSessionApplicationEffects(
                authorizeServer: { server in
                    await appLockManager.ensureServerUnlocked(server)
                },
                refreshLiveActivity: { connectionStates in
                    liveActivityManager.refresh(with: connectionStates)
                },
                recordSuccessfulConnection: { id, transport in
                    engagementTracker.recordSuccessfulConnection(
                        id: id,
                        transport: transport
                    )
                },
                noteTerminalSessionEnded: { otherTerminalsActive in
                    engagementTracker.noteTerminalSessionEnded(
                        otherTerminalsActive: otherTerminalsActive
                    )
                },
                recordSplitPaneCreated: {
                    analyticsTracker.trackSplitPaneCreated()
                }
            ),
            remoteMosh: remoteMosh,
            eternalTerminalRuntime: .live(
                resumeStore: eternalTerminalResumeStore,
                analyticsTracker: analyticsTracker,
                remoteTmux: remoteTmux,
                sshClientFactory: sshClientFactory
            )
        )
        return TerminalTabManager(
            snapshotStore: UserDefaultsTerminalTabSnapshotStore(
                defaults: defaults,
                key: persistenceKey
            ),
            dependencies: dependencies,
            tmuxConfiguration: tmuxConfiguration,
            remoteTmux: remoteTmux,
            terminalSurfaceStore: terminalSurfaceStore,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshRecovery: TerminalMoshRecoveryService(
                store: moshResumeStore
            )
        )
    }
}

extension RemoteMoshManager: TerminalRemoteMoshServicing {}

private extension TerminalNetworkReadiness {
    init(_ readiness: NetworkMonitor.Readiness) {
        switch readiness {
        case .unknown:
            self = .unknown
        case .ready:
            self = .ready
        case .unavailable:
            self = .unavailable
        }
    }
}
