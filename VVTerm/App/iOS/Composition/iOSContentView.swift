//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(iOS)
struct iOSContentView: View {
    /// Keeps one tab-open operation alive if its navigation route is popped and retried.
    private struct PendingConnection {
        let operationID: UUID
        let task: Task<TerminalTab, Error>
    }

    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let statsDependencies: ServerStatsScreenDependencies
    let terminalSecurityActions: TerminalSecurityActions
    let serverFormDependencies: ServerFormDependencies
    let voiceModelManagers: VoiceSettingsModelManagerOwner
    let voiceInputRuntimeStore: VoiceInputRuntimeStore
    let analyticsOptOutAction: AnalyticsOptOutAction
    private let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    @ObservedObject private var serverManager: ServerManager
    @ObservedObject private var engagementTracker: EngagementTracker
    private let tabManager: TerminalTabManager
    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager
    @Environment(\.requestReview) private var requestReview

    @State private var selectedWorkspace: Workspace?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var terminalRoute: ServerTerminalNavigationRoute?
    @State private var pendingConnections: [UUID: PendingConnection] = [:]
    @State private var showingTabLimitAlert = false
    @State private var lockedServerName: String?

    init(
        serverManager: ServerManager,
        engagementTracker: EngagementTracker,
        tabManager: TerminalTabManager,
        fileTabs: RemoteFileTabManager,
        fileBrowser: RemoteFileBrowserStore,
        statsDependencies: ServerStatsScreenDependencies,
        terminalSecurityActions: TerminalSecurityActions,
        serverFormDependencies: ServerFormDependencies,
        voiceModelManagers: VoiceSettingsModelManagerOwner,
        voiceInputRuntimeStore: VoiceInputRuntimeStore,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        analyticsOptOutAction: AnalyticsOptOutAction
    ) {
        _serverManager = ObservedObject(wrappedValue: serverManager)
        _engagementTracker = ObservedObject(wrappedValue: engagementTracker)
        self.tabManager = tabManager
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.statsDependencies = statsDependencies
        self.terminalSecurityActions = terminalSecurityActions
        self.serverFormDependencies = serverFormDependencies
        self.voiceModelManagers = voiceModelManagers
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.analyticsOptOutAction = analyticsOptOutAction
    }

    private var preferredConnectView: ConnectionViewTabID {
        viewTabConfig.effectiveDefaultTab()
    }

    private var terminalPresentation: Binding<Bool> {
        Binding(
            get: { terminalRoute != nil },
            set: { isPresented in
                if !isPresented {
                    terminalRoute = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ServerListScreen(
                serverManager: serverManager,
                tabManager: tabManager,
                fileTabs: fileTabs,
                fileBrowser: fileBrowser,
                statsDependencies: statsDependencies,
                analyticsOptOutAction: analyticsOptOutAction,
                serverFormDependencies: serverFormDependencies,
                voiceModelManagers: voiceModelManagers,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                onServerSelected: { server in
                    beginConnection(to: server)
                },
                onActiveConnectionSelected: { server in
                    terminalRoute = .active(serverId: server.id)
                }
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                ServerLocalStorageNotice(serverManager: serverManager)
            }
            .navigationDestination(isPresented: terminalPresentation) {
                if let terminalRoute {
                    ServerTerminalRoute(
                        tabManager: tabManager,
                        serverManager: serverManager,
                        fileTabs: fileTabs,
                        fileBrowser: fileBrowser,
                        statsDependencies: statsDependencies,
                        terminalSecurityActions: terminalSecurityActions,
                        serverFormDependencies: serverFormDependencies,
                        voiceModelManagers: voiceModelManagers,
                        voiceInputRuntimeStore: voiceInputRuntimeStore,
                        analyticsOptOutAction: analyticsOptOutAction,
                        route: terminalRoute,
                        makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                        onBack: { self.terminalRoute = nil }
                    )
                }
            }
        }
        .navigationBarAppearance(backgroundColor: .clear, isTranslucent: true, shadowColor: .clear)
        .adaptiveSoftScrollEdges()
        .onAppear {
            reconcileWorkspaceSelection(serverManager.workspaces)
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            reconcileWorkspaceSelection(workspaces)
        }
        .onChange(of: selectedWorkspace?.id) { _ in
            selectedEnvironment = WorkspaceSelectionPolicy.environment(
                current: selectedEnvironment,
                workspace: selectedWorkspace
            )
        }
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
        .onChange(of: terminalRoute?.serverId) { serverId in
            if serverId == nil {
                engagementTracker.noteTerminalSessionEnded(
                    otherTerminalsActive: false
                )
            }
        }
        .onChange(of: engagementTracker.reviewRequestToken) { _ in
            requestReview()
        }
        .lockedItemAlert(
            .server,
            itemName: lockedServerName ?? "",
            isPresented: Binding(
                get: { lockedServerName != nil },
                set: { if !$0 { lockedServerName = nil } }
            )
        )
    }

    private func reconcileWorkspaceSelection(_ workspaces: [Workspace]) {
        selectedWorkspace = WorkspaceSelectionPolicy.workspace(
            current: selectedWorkspace,
            available: workspaces
        )
        selectedEnvironment = WorkspaceSelectionPolicy.environment(
            current: selectedEnvironment,
            workspace: selectedWorkspace
        )
    }

    private func beginConnection(to server: Server) {
        guard terminalRoute == nil else { return }

        let attemptID = UUID()
        terminalRoute = .connecting(server: server, attemptID: attemptID)
        tabManager.sessionState.selectView(preferredConnectView, for: server.id)
        let pendingConnection = pendingConnection(for: server)

        Task {
            defer {
                finishPendingConnection(pendingConnection, for: server.id)
            }

            do {
                let tab = try await pendingConnection.task.value
                guard resolveConnection(for: attemptID, as: .succeeded) else {
                    return
                }
                tabManager.sessionState.selectView(preferredConnectView, for: server.id)
                tabManager.sessionState.selectTab(tab.id, for: server.id)
            } catch {
                guard resolveConnection(for: attemptID, as: .failed) else { return }
                guard let error = error as? VVTermError else { return }
                switch error {
                case .proRequired:
                    showingTabLimitAlert = true
                case .serverLocked(let name):
                    lockedServerName = name
                default:
                    break
                }
            }
        }
    }

    @discardableResult
    private func resolveConnection(
        for attemptID: UUID,
        as resolution: ServerTerminalNavigationRoute.ConnectionResolution
    ) -> Bool {
        guard let terminalRoute,
              terminalRoute.connectionAttemptID == attemptID else {
            return false
        }
        self.terminalRoute = terminalRoute.resolvingConnection(
            for: attemptID,
            as: resolution
        )
        return true
    }

    private func pendingConnection(for server: Server) -> PendingConnection {
        if let pendingConnection = pendingConnections[server.id] {
            return pendingConnection
        }

        let pendingConnection = PendingConnection(
            operationID: UUID(),
            task: Task {
                try await tabManager.openTab(for: server)
            }
        )
        pendingConnections[server.id] = pendingConnection
        return pendingConnection
    }

    private func finishPendingConnection(
        _ pendingConnection: PendingConnection,
        for serverID: UUID
    ) {
        guard let currentConnection = pendingConnections[serverID],
              currentConnection.operationID == pendingConnection.operationID else {
            return
        }
        pendingConnections.removeValue(forKey: serverID)
    }
}

#endif
