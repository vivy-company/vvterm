import Foundation
import Combine
import Testing
@testable import VVTerm

extension TerminalTabManagerLifecycleTests {
    @Suite(.serialized)
    @MainActor
    struct TabsAndSplits: TerminalTabManagerTestSupport {
        @Test
        func openingTabSeedsWorkingDirectoryOnlyFromSelectedTabOnSameServer() async throws {
            try await withCleanManager { manager in
                let firstServer = makeServer(name: "First")
                let secondServer = makeServer(name: "Second")
    
                let firstTab = try await manager.openTab(for: firstServer)
                manager.updatePaneWorkingDirectory(firstTab.rootPaneId, rawDirectory: "/srv/first")
    
                let otherServerTab = try await manager.openTab(for: secondServer)
                #expect(manager.sessionState.paneState(for: otherServerTab.rootPaneId)?.workingDirectory == nil)
                #expect(manager.sessionState.paneState(for: otherServerTab.rootPaneId)?.seedPaneId == nil)
    
                let secondFirstServerTab = try await manager.openTab(for: firstServer)
                #expect(
                    manager.sessionState.paneState(for: secondFirstServerTab.rootPaneId)?.workingDirectory
                        == "/srv/first"
                )
                #expect(manager.sessionState.paneState(for: secondFirstServerTab.rootPaneId)?.seedPaneId == firstTab.rootPaneId)
            }
        }
    
        @Test
        func oscWorkingDirectoryRejectsPercentEncodedCommandControls() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Unsafe PWD")
                installTab(tab, in: manager)
    
                manager.updatePaneWorkingDirectory(
                    tab.rootPaneId,
                    rawDirectory: "file://host/C:/safe%0D%0Awhoami"
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.workingDirectory == nil)
            }
        }
    
        @Test
        func sharedStatsClientSkipsSelectedMoshTransport() async {
            await withCleanManager { manager in
                let server = makeServer(connectionMode: .mosh)
                let tab = TerminalTab(serverId: server.id, title: server.name)
                installTab(tab, in: manager)
    
                let client = SSHClient.testing()
                #expect(await startAndRegisterShell(
                    client,
                    paneId: tab.rootPaneId,
                    serverId: server.id,
                    transportState: .mosh,
                    in: manager
                ))
    
                #expect(manager.transportCoordinator.sshClient(for: server.id) === client)
                #expect(manager.transportCoordinator.sharedStatsClient(for: server.id) == nil)
            }
        }
    
        @Test
        func splitPaneUsesLatestManagerStateWhenViewTabIsStale() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Split")
                installTab(tab, in: manager)
    
                guard let firstSplitPane = manager.splitRight(
                    tab: tab,
                    paneId: tab.rootPaneId,
                    hasProAccess: true
                ) else {
                    Issue.record("First split failed unexpectedly")
                    return
                }
    
                guard let secondSplitPane = manager.splitDown(
                    tab: tab,
                    paneId: firstSplitPane,
                    hasProAccess: true
                ) else {
                    Issue.record("Second split failed unexpectedly")
                    return
                }
    
                guard let latestTab = manager.sessionState.tabs(for: tab.serverId).first else {
                    Issue.record("Expected tab to exist after split")
                    return
                }
    
                #expect(Set(latestTab.allPaneIds) == [tab.rootPaneId, firstSplitPane, secondSplitPane])
            }
        }
    
        @Test
        func focusingPaneUsesLatestManagerStateWhenViewTabIsStale() async {
            await withCleanManager { manager in
                let staleTab = TerminalTab(serverId: UUID(), title: "Focus stale tab")
                installTab(staleTab, in: manager, connectionState: .connected)
    
                guard let firstSplitPane = manager.splitRight(
                    tab: staleTab,
                    paneId: staleTab.rootPaneId,
                    hasProAccess: true
                ), let secondSplitPane = manager.splitDown(
                    tab: staleTab,
                    paneId: firstSplitPane,
                    hasProAccess: true
                ) else {
                    Issue.record("Expected split panes")
                    return
                }
    
                manager.focusPane(in: staleTab, paneId: firstSplitPane)
    
                guard let currentTab = manager.sessionState.tabs(for: staleTab.serverId).first else {
                    Issue.record("Expected current tab")
                    return
                }
                #expect(currentTab.focusedPaneId == firstSplitPane)
                #expect(Set(currentTab.allPaneIds) == [
                    staleTab.rootPaneId,
                    firstSplitPane,
                    secondSplitPane,
                ])
            }
        }
    
        @Test
        func splitKeyboardCommandsNavigateZoomAndResizeLatestLayout() async {
            await withCleanManager { manager in
                let staleTab = TerminalTab(serverId: UUID(), title: "Keyboard splits")
                installTab(staleTab, in: manager, connectionState: .connected)
    
                #expect(manager.performSplitCommand(.splitRight, in: staleTab, hasProAccess: true) == .performed)
                #expect(manager.performSplitCommand(.splitDown, in: staleTab, hasProAccess: true) == .performed)
    
                guard let threePaneTab = manager.sessionState.tabs(for: staleTab.serverId).first,
                      case .split(let originalRoot) = threePaneTab.layout else {
                    Issue.record("Expected three-pane split layout")
                    return
                }
                let bottomRightPane = threePaneTab.focusedPaneId
    
                manager.focusPane(in: staleTab, paneId: staleTab.rootPaneId)
                #expect(!manager.canPerformSplitCommand(.selectAbove, in: staleTab))
                #expect(!manager.canPerformSplitCommand(.selectBelow, in: staleTab))
                #expect(manager.performSplitCommand(.selectAbove, in: staleTab, hasProAccess: true) == .unavailable)
                #expect(manager.performSplitCommand(.selectBelow, in: staleTab, hasProAccess: true) == .unavailable)
                #expect(manager.sessionState.tabs(for: staleTab.serverId).first?.focusedPaneId == staleTab.rootPaneId)
                manager.focusPane(in: staleTab, paneId: bottomRightPane)
    
                #expect(manager.performSplitCommand(.selectLeft, in: staleTab, hasProAccess: true) == .performed)
                #expect(manager.sessionState.tabs(for: staleTab.serverId).first?.focusedPaneId == staleTab.rootPaneId)
    
                #expect(manager.performSplitCommand(.selectNext, in: staleTab, hasProAccess: true) == .performed)
                let nextPane = manager.sessionState.tabs(for: staleTab.serverId).first?.focusedPaneId
                #expect(nextPane != nil)
                #expect(nextPane != staleTab.rootPaneId)
    
                #expect(manager.performSplitCommand(.toggleZoom, in: staleTab, hasProAccess: true) == .performed)
                #expect(manager.isSplitZoomed(in: threePaneTab))
                #expect(manager.performSplitCommand(.selectNext, in: staleTab, hasProAccess: true) == .performed)
                #expect(manager.isSplitZoomed(in: threePaneTab))
    
                #expect(manager.performSplitCommand(.moveDividerLeft, in: staleTab, hasProAccess: true) == .performed)
                guard let resizedTab = manager.sessionState.tabs(for: staleTab.serverId).first,
                      case .split(let resizedRoot) = resizedTab.layout else {
                    Issue.record("Expected resized split layout")
                    return
                }
                #expect(resizedRoot.ratio < originalRoot.ratio)
    
                #expect(manager.performSplitCommand(.equalize, in: staleTab, hasProAccess: true) == .performed)
                #expect(manager.performSplitCommand(.closeFocusedPane, in: staleTab, hasProAccess: true) == .requiresCloseConfirmation)
                #expect(manager.sessionState.tabs(for: staleTab.serverId).first?.paneCount == 3)
    
                #expect(manager.performSplitCommand(.toggleZoom, in: staleTab, hasProAccess: true) == .performed)
                #expect(!manager.isSplitZoomed(in: threePaneTab))
            }
        }
    
        @Test
        func splitCreationCommandReportsUpgradeRequirement() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Free split")
                installTab(tab, in: manager, connectionState: .connected)
    
                #expect(manager.performSplitCommand(.splitRight, in: tab, hasProAccess: false) == .requiresUpgrade)
                #expect(manager.sessionState.tabs(for: tab.serverId).first?.paneCount == 1)
            }
        }
    
        @Test
        func closingSplitPaneKeepsSiblingConnected() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Close split")
                installTab(tab, in: manager, connectionState: .connected)
                guard let splitPane = manager.splitRight(
                    tab: tab,
                    paneId: tab.rootPaneId,
                    hasProAccess: true
                ) else {
                    Issue.record("Expected split pane")
                    return
                }
                manager.updatePaneState(splitPane, connectionState: .connected)
    
                manager.closePane(tab: tab, paneId: splitPane)
    
                #expect(manager.sessionState.paneState(for: splitPane) == nil)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .connected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
                #expect(manager.sessionState.tabs(for: tab.serverId).first?.allPaneIds == [tab.rootPaneId])
            }
        }
    
        @Test
        func closeTabUsesLatestManagerStateWhenViewTabIsStale() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Close stale tab")
                installTab(tab, in: manager, connectionState: .connected)
    
                guard let splitPane = manager.splitRight(
                    tab: tab,
                    paneId: tab.rootPaneId,
                    hasProAccess: true
                ) else {
                    Issue.record("Split failed unexpectedly")
                    return
                }
                manager.updatePaneState(splitPane, connectionState: .connected)
    
                #expect(
                    TerminalLiveActivityPolicy.snapshot(
                        for: manager.sessionState.allPaneStates.map(\.connectionState)
                    )?.activeCount == 2
                )
    
                manager.closeTab(tab)
    
                #expect(manager.sessionState.tabs(for: tab.serverId).isEmpty)
                #expect(manager.sessionState.allPaneStates.isEmpty)
                #expect(
                    TerminalLiveActivityPolicy.snapshot(
                        for: manager.sessionState.allPaneStates.map(\.connectionState)
                    ) == nil
                )
            }
        }
    
        #if os(iOS)
        @Test
        func applicationTerminationPreservesTabsAndCompletesActivityCleanup() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Termination")
                installTab(tab, in: manager, connectionState: .connected)
    
                let appDelegate = AppDelegate()
                let appLockManager = AppLockManager()
                let defaults = UserDefaults.standard
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
                        freePlanTracker: AnalyticsTracker.shared,
                        actionAuthorizer: appLockManager,
                        syncRepository: cloudKitSync.coordinator,
                        defaultWorkspaceName: { "Default" },
                        canonicalDefaultWorkspaceNames: { ["Default"] },
                        now: Date.init,
                        makeID: UUID.init
                    ),
                    startsAutomatically: false
                )
                appDelegate.configure(
                    tabManager: manager,
                    serverManager: serverManager,
                    appLockManager: appLockManager,
                    lifecycleDependencies: AppLifecycleDependencies(
                        subscribeToRemoteChanges: {},
                        refreshNetwork: {},
                        endLiveActivitiesForApplicationTermination: { true }
                    )
                )
                #expect(appDelegate.handleApplicationWillTerminate())
    
                #expect(manager.sessionState.tabs(for: tab.serverId).map(\.id) == [tab.id])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            }
        }
        #endif
    }
}
