import ETSession
import Foundation
import MoshCore
import Testing
@testable import VVTerm

private actor LiveCompositionRemoteTmuxSpy: TerminalRemoteTmuxServicing {
    private var killedSessionNames: [String] = []

    func killedSessions() -> [String] {
        killedSessionNames
    }

    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability {
        .unsupported
    }

    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? {
        nil
    }

    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession] {
        []
    }

    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend?
    ) async {}

    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws {}

    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {
        killedSessionNames.append(sessionName)
    }

    func cleanupLegacySessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}

    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async -> String? {
        nil
    }
}

private actor LiveCompositionRemoteMoshSpy: TerminalRemoteMoshServicing {
    func installMoshServer(using client: SSHClient) async throws {}
}

private final class LiveCompositionEternalTerminalResumeStore:
    EternalTerminalResumeStoring,
    @unchecked Sendable
{
    let checkpointPaneIDs: Set<UUID>

    init(checkpointPaneIDs: Set<UUID>) {
        self.checkpointPaneIDs = checkpointPaneIDs
    }

    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { checkpointPaneIDs.contains(paneId) }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

private final class LiveCompositionMoshResumeStore: MoshResumeStoring {
    let checkpointPaneIDs: Set<UUID>

    init(checkpointPaneIDs: Set<UUID>) {
        self.checkpointPaneIDs = checkpointPaneIDs
    }

    func snapshot(for paneId: UUID) throws -> MoshSnapshot? { nil }
    func hasSnapshot(for paneId: UUID) -> Bool { checkpointPaneIDs.contains(paneId) }
    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {}
    func deleteSnapshot(for paneId: UUID) throws {}
}

@MainActor
private final class LiveCompositionLiveActivityController: TerminalLiveActivityControlling {
    private(set) var targets: [TerminalLiveActivityTarget] = []

    func reconcile(toward target: TerminalLiveActivityTarget) async {
        targets.append(target)
    }

    func endForApplicationTermination() -> Bool {
        true
    }
}

@MainActor
private final class LiveCompositionBiometricAuthService: BiometricAuthServing {
    func availability() -> BiometricAvailability {
        .unavailable(.notAvailable)
    }

    func authenticate(
        reason: BiometricAuthenticationReason,
        allowPasscodeFallback: Bool
    ) async throws {}
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerLiveCompositionTests {
    @Test
    func explicitInputsKeepManagerOwnersIndependent() async throws {
        let firstSuiteName = "TerminalTabManagerLiveCompositionTests.\(UUID().uuidString)"
        let secondSuiteName = "TerminalTabManagerLiveCompositionTests.\(UUID().uuidString)"
        let firstDefaults = try #require(UserDefaults(suiteName: firstSuiteName))
        let secondDefaults = try #require(UserDefaults(suiteName: secondSuiteName))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuiteName)
            secondDefaults.removePersistentDomain(forName: secondSuiteName)
        }
        firstDefaults.set(true, forKey: "terminalTmuxEnabledDefault")
        secondDefaults.set(false, forKey: "terminalTmuxEnabledDefault")

        let firstCheckpointPaneID = UUID()
        let secondCheckpointPaneID = UUID()
        let firstRemoteTmux = LiveCompositionRemoteTmuxSpy()
        let secondRemoteTmux = LiveCompositionRemoteTmuxSpy()
        let firstSurfaceStore = GhosttyTerminalSurfaceStore()
        let secondSurfaceStore = GhosttyTerminalSurfaceStore()
        let firstLiveActivityController = LiveCompositionLiveActivityController()
        let secondLiveActivityController = LiveCompositionLiveActivityController()
        let first = makeManager(
            defaults: firstDefaults,
            remoteTmux: firstRemoteTmux,
            eternalTerminalResumeStore: LiveCompositionEternalTerminalResumeStore(
                checkpointPaneIDs: [firstCheckpointPaneID]
            ),
            moshResumeStore: LiveCompositionMoshResumeStore(
                checkpointPaneIDs: [firstCheckpointPaneID]
            ),
            surfaceStore: firstSurfaceStore,
            liveActivityController: firstLiveActivityController,
            applicationIsActive: false
        )
        let second = makeManager(
            defaults: secondDefaults,
            remoteTmux: secondRemoteTmux,
            eternalTerminalResumeStore: LiveCompositionEternalTerminalResumeStore(
                checkpointPaneIDs: [secondCheckpointPaneID]
            ),
            moshResumeStore: LiveCompositionMoshResumeStore(
                checkpointPaneIDs: [secondCheckpointPaneID]
            ),
            surfaceStore: secondSurfaceStore,
            liveActivityController: secondLiveActivityController,
            applicationIsActive: true
        )

        let firstOwnsSurfaceStore =
            (first.terminalSurfaceStore as AnyObject) === firstSurfaceStore
        let secondOwnsSurfaceStore =
            (second.terminalSurfaceStore as AnyObject) === secondSurfaceStore
        #expect(firstOwnsSurfaceStore)
        #expect(secondOwnsSurfaceStore)
        #expect(first.tmuxCoordinator.isEnabled(for: UUID()))
        #expect(!second.tmuxCoordinator.isEnabled(for: UUID()))
        #expect(!first.reconnectCoordinator.applicationIsActive)
        #expect(second.reconnectCoordinator.applicationIsActive)
        #expect(
            first.transportCoordinator.hasEternalTerminalCheckpoint(
                for: firstCheckpointPaneID
            )
        )
        #expect(
            !first.transportCoordinator.hasEternalTerminalCheckpoint(
                for: secondCheckpointPaneID
            )
        )
        #expect(first.transportCoordinator.hasMoshCheckpoint(for: firstCheckpointPaneID))
        #expect(!first.transportCoordinator.hasMoshCheckpoint(for: secondCheckpointPaneID))
        #expect(
            second.transportCoordinator.hasEternalTerminalCheckpoint(
                for: secondCheckpointPaneID
            )
        )
        #expect(second.transportCoordinator.hasMoshCheckpoint(for: secondCheckpointPaneID))

        await first.tmuxCoordinator.killSession(
            named: "first-session",
            using: SSHClient.testing()
        )
        #expect(await firstRemoteTmux.killedSessions() == ["first-session"])
        #expect(await secondRemoteTmux.killedSessions().isEmpty)

        let tab = TerminalTab(serverId: UUID(), title: "First")
        first.sessionState.install(
            tab,
            paneState: TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ),
            select: true
        )
        first.sessionState.persistAndRestoreSnapshotForTesting()
        #expect(firstDefaults.data(forKey: "terminalTabsSnapshot.v1") != nil)
        #expect(secondDefaults.data(forKey: "terminalTabsSnapshot.v1") == nil)
        #expect(await waitUntil {
            !firstLiveActivityController.targets.isEmpty
                && !secondLiveActivityController.targets.isEmpty
        })

        await first.resetForTesting()
        await second.resetForTesting()
    }

    private func makeManager(
        defaults: UserDefaults,
        remoteTmux: LiveCompositionRemoteTmuxSpy,
        eternalTerminalResumeStore: LiveCompositionEternalTerminalResumeStore,
        moshResumeStore: LiveCompositionMoshResumeStore,
        surfaceStore: GhosttyTerminalSurfaceStore,
        liveActivityController: LiveCompositionLiveActivityController,
        applicationIsActive: Bool
    ) -> TerminalTabManager {
        let analyticsTracker = AnalyticsTracker.shared
        let applicationIsActiveQuery: @MainActor @Sendable () -> Bool = {
            applicationIsActive
        }
        let appLockManager = AppLockManager(
            defaults: defaults,
            authService: LiveCompositionBiometricAuthService()
        )
        let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
            transport: CloudKitManager.shared,
            defaults: defaults,
            now: Date.init,
            makeID: UUID.init
        )
        let serverManager = ServerManager(
            dependencies: .live(
                defaults: defaults,
                serverCloud: cloudKitSync.serverCloud,
                credentialRepository: KeychainManager.shared,
                knownHosts: KnownHostsManager.shared,
                freePlanTracker: analyticsTracker,
                actionAuthorizer: appLockManager,
                syncRepository: cloudKitSync.coordinator,
                defaultWorkspaceName: { "Default" },
                canonicalDefaultWorkspaceNames: { ["Default"] },
                now: Date.init,
                makeID: UUID.init
            ),
            startsAutomatically: false
        )
        return TerminalTabManagerLiveComposition.makeManager(
            defaults: defaults,
            sshClientFactory: .testing(),
            networkMonitor: .shared,
            appLockManager: appLockManager,
            serverManager: serverManager,
            engagementTracker: EngagementTracker(
                dependencies: .live(
                    defaults: defaults,
                    analytics: analyticsTracker,
                    now: Date.init,
                    calendar: .current,
                    applicationIsActive: applicationIsActiveQuery
                )
            ),
            analyticsTracker: analyticsTracker,
            liveActivityManager: LiveActivityManager(
                controller: liveActivityController
            ),
            remoteMosh: LiveCompositionRemoteMoshSpy(),
            remoteTmux: remoteTmux,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshResumeStore: moshResumeStore,
            terminalSurfaceStore: surfaceStore,
            deviceID: UUID().uuidString.lowercased(),
            themeStyle: {
                TerminalTmuxSessionLiveComposition.themeStyle(for: "Aizen Dark")
            },
            applicationIsActive: applicationIsActiveQuery
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
