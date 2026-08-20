//
//  ServerListScreen+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
struct ServerListScreen: View {
    @ObservedObject var serverManager: ServerManager
    let tabManager: TerminalTabManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let statsDependencies: ServerStatsScreenDependencies
    let analyticsOptOutAction: AnalyticsOptOutAction
    let serverFormDependencies: ServerFormDependencies
    let voiceModelManagers: VoiceSettingsModelManagerOwner
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    let onServerSelected: (Server) -> Void
    let onActiveConnectionSelected: (Server) -> Void

    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var appLockManager: AppLockManager
    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager
    @ObservedObject private var sessionState: TerminalSessionStateStore
    @State private var showingAddServer = false
    @State private var showingAddWorkspace = false
    @State private var showingSettings = false
    @State private var showingWorkspacePicker = false
    @State private var showingCreateEnvironment = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var environmentDeletionError: String?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var serverToMove: Server?
    @State private var lockedServerAlert: Server?
    @State private var showingCustomEnvironmentAlert = false
    @State private var addServerPrefill: ServerFormPrefill?

    init(
        serverManager: ServerManager,
        tabManager: TerminalTabManager,
        fileTabs: RemoteFileTabManager,
        fileBrowser: RemoteFileBrowserStore,
        statsDependencies: ServerStatsScreenDependencies,
        analyticsOptOutAction: AnalyticsOptOutAction,
        serverFormDependencies: ServerFormDependencies,
        voiceModelManagers: VoiceSettingsModelManagerOwner,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        selectedWorkspace: Binding<Workspace?>,
        selectedEnvironment: Binding<ServerEnvironment?>,
        onServerSelected: @escaping (Server) -> Void,
        onActiveConnectionSelected: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        self.tabManager = tabManager
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.statsDependencies = statsDependencies
        self.analyticsOptOutAction = analyticsOptOutAction
        self.serverFormDependencies = serverFormDependencies
        self.voiceModelManagers = voiceModelManagers
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self._selectedWorkspace = selectedWorkspace
        self._selectedEnvironment = selectedEnvironment
        self.onServerSelected = onServerSelected
        self.onActiveConnectionSelected = onActiveConnectionSelected
        self._sessionState = ObservedObject(wrappedValue: tabManager.sessionState)
    }

    private var canAddServer: Bool {
        !serverManager.workspaces.isEmpty
    }

    var body: some View {
        List {
            serversSection
            activeConnectionsSection
        }
        .accessibilityIdentifier("vvterm.serverList.list")
        .overlay(alignment: .center) {
            if filteredServers.isEmpty {
                NoServersEmptyState(
                    onAddServer: { presentAddServer() },
                    onAddWorkspace: { showingAddWorkspace = true },
                    requiresWorkspace: serverManager.workspaces.isEmpty
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search servers")
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                workspaceToolbarButton
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentAddServer()
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .accessibilityIdentifier("vvterm.serverList.settings")
            }
        }
        .sheet(isPresented: $showingAddServer) {
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    prefill: addServerPrefill,
                    dependencies: serverFormDependencies,
                    makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                    onSave: { _ in showingAddServer = false }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingAddWorkspace) {
            NavigationStack {
                WorkspaceFormSheet(
                    serverManager: serverManager,
                    onSave: { workspace in
                        selectedWorkspace = workspace
                        showingAddWorkspace = false
                    }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                statsPreferencesStore: statsDependencies.preferencesStore,
                voiceModelManagers: voiceModelManagers,
                analyticsOptOutAction: analyticsOptOutAction
            )
                .modifier(AppearanceModifier())
                .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingWorkspacePicker) {
            NavigationStack {
                WorkspacePickerSheet(
                    serverManager: serverManager,
                    selectedWorkspace: $selectedWorkspace,
                    onDismiss: { showingWorkspacePicker = false }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $serverToEdit) { server in
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    server: server,
                    dependencies: serverFormDependencies,
                    makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                    onSave: { updatedServer in
                        handleSavedServer(updatedServer, originalServer: server)
                        serverToEdit = nil
                    }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $serverToMove) { server in
            NavigationStack {
                MoveServerSheet(
                    serverManager: serverManager,
                    server: server,
                    onMove: { updatedServer in
                        handleSavedServer(updatedServer, originalServer: server)
                        serverToMove = nil
                    }
                )
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingCreateEnvironment) {
            if let workspace = selectedWorkspace {
                EnvironmentFormSheet(
                    serverManager: serverManager,
                    workspace: workspace,
                    onSave: { updatedWorkspace, newEnvironment in
                        selectedWorkspace = updatedWorkspace
                        selectedEnvironment = newEnvironment
                        showingCreateEnvironment = false
                    }
                )
                .adaptiveSoftScrollEdges()
            }
        }
        .sheet(item: $editingEnvironment) { environment in
            if let workspace = selectedWorkspace {
                EnvironmentFormSheet(
                    serverManager: serverManager,
                    workspace: workspace,
                    environment: environment,
                    onSave: { updatedWorkspace, updatedEnvironment in
                        selectedWorkspace = updatedWorkspace
                        if selectedEnvironment?.id == updatedEnvironment.id {
                            selectedEnvironment = updatedEnvironment
                        }
                        editingEnvironment = nil
                    }
                )
                .adaptiveSoftScrollEdges()
            }
        }
        .alert(String(localized: "Delete Environment?"), isPresented: Binding(
            get: { environmentToDelete != nil },
            set: { if !$0 { environmentToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                guard let environment = environmentToDelete,
                      let workspace = selectedWorkspace else {
                    environmentToDelete = nil
                    return
                }
                Task {
                    defer { environmentToDelete = nil }
                    do {
                        let result = try await serverManager.deleteEnvironment(
                            environment,
                            in: workspace,
                            fallback: .production
                        )
                        selectedWorkspace = result.workspace
                        selectedEnvironment = WorkspaceSelectionPolicy.environment(
                            current: selectedEnvironment,
                            afterDeleting: environment.id,
                            result: result
                        )
                    } catch {
                        environmentDeletionError = error.localizedDescription
                    }
                }
            }
        } message: {
            let name = environmentToDelete?.displayName ?? String(localized: "Custom")
            Text(String(format: String(localized: "Servers in '%@' will be moved to Production."), name))
        }
        .alert(String(localized: "Environment Not Deleted"), isPresented: Binding(
            get: { environmentDeletionError != nil },
            set: { if !$0 { environmentDeletionError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(environmentDeletionError ?? "")
        }
        .lockedItemAlert(
            .server,
            itemName: lockedServerAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedServerAlert != nil },
                set: { if !$0 { lockedServerAlert = nil } }
            )
        )
        .proFeatureAlert(
            title: String(localized: "Custom Environments"),
            message: String(localized: "Upgrade to Pro for custom environments"),
            source: .customEnvironment,
            isPresented: $showingCustomEnvironmentAlert
        )
        .onChange(of: showingAddWorkspace) { isPresented in
            guard !isPresented else { return }
            resumePendingPrefilledAddServerIfNeeded()
        }
        .onChange(of: showingAddServer) { isPresented in
            if !isPresented {
                addServerPrefill = nil
            }
        }
    }

    private func handleSavedServer(_ server: Server, originalServer: Server) {
        let movedAcrossWorkspaces = originalServer.workspaceId != server.workspaceId

        if movedAcrossWorkspaces,
           let destinationWorkspace = serverManager.workspace(withId: server.workspaceId) {
            selectedWorkspace = destinationWorkspace
            selectedEnvironment = nil
            return
        }

        if let selectedEnvironment,
           selectedEnvironment.id != server.environment.id {
            self.selectedEnvironment = nil
        }
    }

    private var environmentOptions: [ServerEnvironment] {
        selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments
    }

    private var selectedWorkspaceName: String {
        selectedWorkspace?.name ?? String(localized: "Select Workspace")
    }

    private var selectedWorkspaceColorHex: String {
        selectedWorkspace?.colorHex ?? "#007AFF"
    }

    private var filteredServerCountText: String {
        let serverCount = filteredServers.count
        if serverCount == 1 {
            return String(format: String(localized: "%lld server"), Int64(serverCount))
        }
        return String(format: String(localized: "%lld servers"), Int64(serverCount))
    }

    private var workspaceToolbarButton: some View {
        Button {
            showingWorkspacePicker = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.fromHex(selectedWorkspaceColorHex))
                    .frame(width: 8, height: 8)

                Text(selectedWorkspaceName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedWorkspaceName)
        .accessibilityValue(filteredServerCountText)
        .accessibilityHint(String(localized: "Opens the workspace picker"))
    }

    @ViewBuilder
    private var serversSection: some View {
        Section {
            if filteredServers.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredServers) { server in
                    ServerListRow(
                        serverManager: serverManager,
                        server: server,
                        onTap: { onServerSelected(server) },
                        onEdit: { serverToEdit = server },
                        onMove: { serverToMove = server },
                        onLockedTap: { lockedServerAlert = server }
                    )
                    .accessibilityIdentifier(
                        "vvterm.serverList.server.\(server.id.uuidString)"
                    )
                }
            }
        } header: {
            HStack {
                Text("Servers")

                Spacer()

                if selectedWorkspace != nil {
                    EnvironmentFilterMenu(
                        selected: $selectedEnvironment,
                        environments: environmentOptions,
                        serverCounts: serverCountsByEnvironment,
                        onCreateCustom: {
                            if storeManager.allowsProFeatures {
                                showingCreateEnvironment = true
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        },
                        onEditCustom: { environment in
                            if storeManager.allowsProFeatures {
                                editingEnvironment = environment
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        },
                        onDeleteCustom: { environment in
                            if storeManager.allowsProFeatures {
                                environmentToDelete = environment
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var activeConnectionsSection: some View {
        if !activeConnections.isEmpty && !filteredServers.isEmpty {
            Section {
                ForEach(activeConnections) { connection in
                    ActiveConnectionListRow(
                        title: connection.title,
                        status: connection.status,
                        tmuxStatus: connection.tmuxStatus,
                        tabCount: connection.tabCount,
                        onOpen: { openActiveConnection(connection) },
                        onDisconnect: { disconnectActiveConnection(connection) }
                    )
                    .accessibilityIdentifier(
                        "vvterm.serverList.activeConnection.\(connection.id.uuidString)"
                    )
                }
            } header: {
                Text("Active Connections")
            }
        }
    }

    private var activeConnections: [ActiveServerSummary] {
        ActiveServerSummary.makeAll(
            tabManager: tabManager,
            fileTabs: fileTabs,
            server: { server(for: $0) },
            viewTabConfig: viewTabConfig
        )
    }

    private var filteredServers: [Server] {
        guard let workspace = selectedWorkspace else {
            // If no workspace selected, show all servers
            let allServers = serverManager.servers
            if searchText.isEmpty { return allServers }
            let lowercased = searchText.lowercased()
            return allServers.filter {
                $0.name.lowercased().contains(lowercased) ||
                $0.host.lowercased().contains(lowercased)
            }
        }

        var servers = serverManager.servers(in: workspace, environment: selectedEnvironment)

        if !searchText.isEmpty {
            let lowercased = searchText.lowercased()
            servers = servers.filter {
                $0.name.lowercased().contains(lowercased) ||
                $0.host.lowercased().contains(lowercased)
            }
        }

        return servers.sorted { $0.name < $1.name }
    }

    private var serverCountsByEnvironment: [UUID: Int] {
        guard let workspace = selectedWorkspace else { return [:] }

        var counts: [UUID: Int] = [:]
        let workspaceServers = serverManager.servers.filter { $0.workspaceId == workspace.id }

        for env in workspace.environments {
            counts[env.id] = workspaceServers.filter { $0.environment.id == env.id }.count
        }

        return counts
    }

    private func presentAddServer(prefill: ServerFormPrefill? = nil) {
        addServerPrefill = prefill
        switch ServerCreationPresentationPolicy.initialStep(canAddServer: canAddServer) {
        case .createWorkspace:
            showingAddWorkspace = true
        case .createServer:
            showingAddServer = true
        }
    }

    private func resumePendingPrefilledAddServerIfNeeded() {
        guard ServerCreationPresentationPolicy.shouldResumePrefilledServer(
            hasPrefill: addServerPrefill != nil,
            canAddServer: canAddServer,
            isPresentingServer: showingAddServer
        ) else { return }
        showingAddServer = true
    }

    private func openActiveConnection(_ connection: ActiveServerSummary) {
        Task {
            guard let serverToUnlock = server(for: connection.id) else { return }
            guard await appLockManager.ensureServerUnlocked(serverToUnlock) else { return }
            guard let currentConnection = activeConnections.first(where: {
                $0.id == connection.id
            }), let currentServer = server(for: connection.id) else {
                return
            }

            if let tab = currentConnection.terminalTab {
                tabManager.sessionState.selectTab(tab.id, for: currentServer.id)
            }
            tabManager.sessionState.selectView(currentConnection.targetView, for: currentServer.id)
            onActiveConnectionSelected(currentServer)
        }
    }

    private func disconnectActiveConnection(_ connection: ActiveServerSummary) {
        fileBrowser.disconnect(serverId: connection.id)
        fileTabs.disconnect(serverId: connection.id)
        tabManager.disconnectServer(connection.id)
    }

    private func server(for serverId: UUID) -> Server? {
        serverManager.servers.first { $0.id == serverId }
    }
}
#endif
