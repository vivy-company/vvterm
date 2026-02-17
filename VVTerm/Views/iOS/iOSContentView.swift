//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
struct iOSContentView: View {
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var sessionManager = ConnectionSessionManager.shared

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var showingTerminal = false
    @State private var showingTabLimitAlert = false
    @State private var lockedServerName: String?
    @State private var connectingServer: Server?
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            iOSServerListView(
                serverManager: serverManager,
                sessionManager: sessionManager,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                showingTerminal: $showingTerminal,
                onServerSelected: { server in
                    Task {
                        await MainActor.run {
                            selectedServer = server
                            connectingServer = server
                            isConnecting = true
                            showingTerminal = true
                        }

                        do {
                            _ = try await sessionManager.openConnection(to: server)
                            await MainActor.run {
                                isConnecting = false
                                connectingServer = nil
                            }
                        } catch let error as VVTermError {
                            await MainActor.run {
                                isConnecting = false
                                connectingServer = nil
                                showingTerminal = false

                                switch error {
                                case .proRequired:
                                    showingTabLimitAlert = true
                                case .serverLocked(let name):
                                    lockedServerName = name
                                default:
                                    break
                                }
                            }
                        } catch {
                            await MainActor.run {
                                isConnecting = false
                                connectingServer = nil
                                showingTerminal = false
                            }
                        }
                    }
                }
            )
            .navigationDestination(isPresented: $showingTerminal) {
                iOSTerminalView(
                    sessionManager: sessionManager,
                    serverManager: serverManager,
                    connectingServer: connectingServer,
                    isConnecting: isConnecting,
                    onBack: { showingTerminal = false }
                )
            }
        }
        .navigationBarAppearance(backgroundColor: .clear, isTranslucent: true, shadowColor: .clear)
        .onAppear {
            // Select first workspace on appear
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        // Sync navigation state with session state - dismiss terminal if session is gone
        .onChangeCompat(of: sessionManager.sessions) { _ in
            if showingTerminal && sessionManager.selectedSession == nil {
                showingTerminal = false
            }
            if let connectingServer,
               sessionManager.sessions.contains(where: { $0.serverId == connectingServer.id }) {
                isConnecting = false
                self.connectingServer = nil
            }
        }
        .onChange(of: sessionManager.selectedSessionId) { selectedId in
            if showingTerminal && selectedId == nil {
                showingTerminal = false
            }
        }
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
        .lockedItemAlert(
            .server,
            itemName: lockedServerName ?? "",
            isPresented: Binding(
                get: { lockedServerName != nil },
                set: { if !$0 { lockedServerName = nil } }
            )
        )
    }
}

struct iOSServerListView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    @Binding var showingTerminal: Bool
    let onServerSelected: (Server) -> Void

    @ObservedObject private var storeManager = StoreManager.shared

    @State private var showingAddServer = false
    @State private var showingLocalDiscovery = false
    @State private var showingAddWorkspace = false
    @State private var showingSettings = false
    @State private var showingWorkspacePicker = false
    @State private var showingCreateEnvironment = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var lockedServerAlert: Server?
    @State private var navigationBarAppearanceToken = UUID()
    @State private var showingCustomEnvironmentAlert = false
    @State private var addServerPrefill: ServerFormPrefill?
    @State private var queuedDiscoveryPrefill: ServerFormPrefill?
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    var body: some View {
        List {
            // Workspace Picker Section
            Section {
                Button {
                    showingWorkspacePicker = true
                } label: {
                    HStack {
                        Circle()
                            .fill(Color.fromHex(selectedWorkspace?.colorHex ?? "#007AFF"))
                            .frame(width: 10, height: 10)

                        Text(selectedWorkspace?.name ?? String(localized: "Select Workspace"))
                            .foregroundStyle(.primary)

                        Spacer()
                        let serverCount = filteredServers.count
                        Text(serverCount == 1
                             ? String(format: String(localized: "%lld server"), Int64(serverCount))
                             : String(format: String(localized: "%lld servers"), Int64(serverCount))
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Workspace")
            }

            // Servers Section
            Section {
                if filteredServers.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredServers) { server in
                        iOSServerRow(
                            server: server,
                            onTap: { onServerSelected(server) },
                            onEdit: { serverToEdit = server },
                            onLockedTap: { lockedServerAlert = server }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Servers")

                    Spacer()

                    if selectedWorkspace != nil {
                        iOSEnvironmentFilterMenu(
                            selected: $selectedEnvironment,
                            environments: environmentOptions,
                            serverCounts: serverCountsByEnvironment,
                            onCreateCustom: {
                                if storeManager.isPro {
                                    showingCreateEnvironment = true
                                } else {
                                    showingCustomEnvironmentAlert = true
                                }
                            },
                            onEditCustom: { environment in
                                if storeManager.isPro {
                                    editingEnvironment = environment
                                } else {
                                    showingCustomEnvironmentAlert = true
                                }
                            },
                            onDeleteCustom: { environment in
                                if storeManager.isPro {
                                    environmentToDelete = environment
                                } else {
                                    showingCustomEnvironmentAlert = true
                                }
                            }
                        )
                    }
                }
            }

            // Active Connections Section
            if !activeConnections.isEmpty && !filteredServers.isEmpty {
                Section {
                    ForEach(activeConnections) { connection in
                        iOSActiveConnectionRow(
                            session: connection.session,
                            tabCount: connection.tabCount,
                            onOpen: {
                                Task {
                                    guard let server = serverManager.servers.first(where: { $0.id == connection.id }) else { return }
                                    guard await AppLockManager.shared.ensureServerUnlocked(server) else { return }
                                    await MainActor.run {
                                        sessionManager.selectSession(connection.session)
                                        showingTerminal = true
                                    }
                                }
                            },
                            onDisconnect: {
                                sessionManager.disconnectServer(connection.id)
                            }
                        )
                    }
                } header: {
                    Text("Active Connections")
                }
            }
        }
        .overlay(alignment: .center) {
            if filteredServers.isEmpty {
                NoServersEmptyState {
                    presentAddServer()
                } onDiscoverLocalDevices: {
                    showingLocalDiscovery = true
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search servers")
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .id(navigationBarAppearanceToken)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingLocalDiscovery = true
                    } label: {
                        Label(String(localized: "Discover Local Devices"), systemImage: "dot.radiowaves.left.and.right")
                    }

                    Button {
                        presentAddServer()
                    } label: {
                        Label("Add Server", systemImage: "server.rack")
                    }

                    Button {
                        showingAddWorkspace = true
                    } label: {
                        Label("Add Workspace", systemImage: "folder.badge.plus")
                    }
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
            }
        }
        .onAppear {
            navigationBarAppearanceToken = UUID()
        }
        .sheet(isPresented: $showingAddServer) {
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    prefill: addServerPrefill,
                    onSave: { _ in showingAddServer = false }
                )
            }
        }
        .sheet(isPresented: $showingLocalDiscovery) {
            LocalDeviceDiscoverySheet { discoveredHost in
                queuedDiscoveryPrefill = ServerFormPrefill(discoveredHost: discoveredHost)
                showingLocalDiscovery = false
            }
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
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .modifier(AppearanceModifier())
        }
        .sheet(isPresented: $showingWorkspacePicker) {
            NavigationStack {
                iOSWorkspacePickerView(
                    serverManager: serverManager,
                    selectedWorkspace: $selectedWorkspace,
                    onDismiss: { showingWorkspacePicker = false }
                )
            }
        }
        .sheet(item: $serverToEdit) { server in
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    server: server,
                    onSave: { _ in serverToEdit = nil }
                )
            }
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
                    let updatedWorkspace = try? await serverManager.deleteEnvironment(
                        environment,
                        in: workspace,
                        fallback: .production
                    )
                    await MainActor.run {
                        if let updatedWorkspace {
                            selectedWorkspace = updatedWorkspace
                        }
                        if selectedEnvironment?.id == environment.id {
                            selectedEnvironment = .production
                        }
                        environmentToDelete = nil
                    }
                }
            }
        } message: {
            let name = environmentToDelete?.displayName ?? String(localized: "Custom")
            Text(String(format: String(localized: "Servers in '%@' will be moved to Production."), name))
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
            isPresented: $showingCustomEnvironmentAlert
        )
        .onChange(of: showingLocalDiscovery) { isPresented in
            guard !isPresented, let queued = queuedDiscoveryPrefill else { return }
            queuedDiscoveryPrefill = nil
            presentAddServer(prefill: queued)
        }
        .onChange(of: showingAddServer) { isPresented in
            if !isPresented {
                addServerPrefill = nil
            }
        }
    }

    private var environmentOptions: [ServerEnvironment] {
        selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments
    }

    private struct ActiveConnection: Identifiable {
        let id: UUID
        let session: ConnectionSession
        let tabCount: Int
    }

    private var activeConnections: [ActiveConnection] {
        let grouped = Dictionary(grouping: sessionManager.sessions, by: { $0.serverId })
        return grouped.compactMap { serverId, sessions in
            guard let session = representativeSession(for: sessions) else { return nil }
            return ActiveConnection(id: serverId, session: session, tabCount: sessions.count)
        }
        .sorted { lhs, rhs in
            lhs.session.title.localizedCaseInsensitiveCompare(rhs.session.title) == .orderedAscending
        }
    }

    private func representativeSession(for sessions: [ConnectionSession]) -> ConnectionSession? {
        if let selectedId = sessionManager.selectedSessionId,
           let match = sessions.first(where: { $0.id == selectedId }) {
            return match
        }
        return sessions.first
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
        showingAddServer = true
    }
}

// MARK: - iOS Environment Filter Menu

struct iOSEnvironmentFilterMenu: View {
    @Binding var selected: ServerEnvironment?
    let environments: [ServerEnvironment]
    let serverCounts: [UUID: Int]
    let onCreateCustom: () -> Void
    let onEditCustom: (ServerEnvironment) -> Void
    let onDeleteCustom: (ServerEnvironment) -> Void

    private var totalCount: Int {
        serverCounts.values.reduce(0, +)
    }

    var body: some View {
        Menu {
            // Built-in environments
            ForEach(ServerEnvironment.builtInEnvironments) { env in
                environmentButton(env)
            }

            // Custom environments
            let customEnvs = environments.filter { !$0.isBuiltIn }
            if !customEnvs.isEmpty {
                Divider()
                ForEach(customEnvs) { env in
                    environmentButton(env)
                }
            }

            Divider()

            Button {
                selected = nil
            } label: {
                HStack {
                    Text("All")
                    Spacer()
                    Text(String(format: String(localized: "(%lld)"), Int64(totalCount)))
                        .foregroundStyle(.secondary)
                    if selected == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                onCreateCustom()
            } label: {
                Label(String(localized: "Custom..."), systemImage: "plus")
            }

            if let selectedEnvironment = selected, !selectedEnvironment.isBuiltIn {
                Divider()

                Button {
                    onEditCustom(selectedEnvironment)
                } label: {
                    Label(
                        String(format: String(localized: "Edit \"%@\"..."), selectedEnvironment.displayName),
                        systemImage: "pencil"
                    )
                }

                Button(role: .destructive) {
                    onDeleteCustom(selectedEnvironment)
                } label: {
                    Label(
                        String(format: String(localized: "Delete \"%@\"..."), selectedEnvironment.displayName),
                        systemImage: "trash"
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(selected?.displayShortName ?? String(localized: "All"))
                    .font(.caption)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func environmentButton(_ env: ServerEnvironment) -> some View {
        Button {
            selected = env
        } label: {
            HStack {
                Circle()
                    .fill(env.color)
                    .frame(width: 8, height: 8)
                Text(env.displayName)
                Spacer()
                Text(String(format: String(localized: "(%lld)"), Int64(serverCounts[env.id] ?? 0)))
                    .foregroundStyle(.secondary)
                if selected?.id == env.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

// MARK: - iOS Terminal View

struct iOSTerminalView: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var serverManager: ServerManager
    let connectingServer: Server?
    let isConnecting: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Delayed flag to allow tab animation to complete before creating terminal
    @State private var shouldShowTerminalBySession: [UUID: Bool] = [:]
    /// Force terminal rebuilds to restart SSH on foreground reconnect
    @State private var reconnectTokenBySession: [UUID: UUID] = [:]
    @State private var showingTabLimitAlert = false
    @State private var serverToEdit: Server?
    @State private var terminalBackgroundColor: Color = .black
    @State private var currentServerId: UUID?
    @State private var pendingCloseSession: ConnectionSession?

    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var serverSessions: [ConnectionSession] {
        guard let currentServerId else { return [] }
        return sessionManager.sessions.filter { $0.serverId == currentServerId }
    }

    private var selectedSession: ConnectionSession? {
        guard let resolvedId = effectiveSelectedSessionId else { return nil }
        return serverSessions.first { $0.id == resolvedId }
    }

    private var selectedServer: Server? {
        if let currentServerId {
            return serverManager.servers.first { $0.id == currentServerId }
        }
        return connectingServer
    }

    private var selectedSessionIdBinding: Binding<UUID?> {
        Binding(
            get: { effectiveSelectedSessionId },
            set: { sessionManager.selectedSessionId = $0 }
        )
    }

    private var isCloseAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingCloseSession != nil },
            set: { newValue in
                if !newValue {
                    pendingCloseSession = nil
                }
            }
        )
    }

    private var effectiveSelectedSessionId: UUID? {
        if let selectedId = sessionManager.selectedSessionId,
           serverSessions.contains(where: { $0.id == selectedId }) {
            return selectedId
        }
        return serverSessions.first?.id
    }

    private var selectedView: String {
        guard let serverId = currentServerId ?? selectedSession?.serverId else { return "stats" }
        return sessionManager.selectedViewByServer[serverId] ?? "stats"
    }

    private func selectedViewBinding(for serverId: UUID) -> Binding<String> {
        Binding(
            get: { sessionManager.selectedViewByServer[serverId] ?? "stats" },
            set: { newValue in
                let current = sessionManager.selectedViewByServer[serverId] ?? "stats"
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    sessionManager.selectedViewByServer[serverId] = newValue
                }
            }
        )
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = sessionManager.tmuxAttachPrompt else { return nil }
                return serverSessions.contains(where: { $0.id == prompt.id }) ? prompt : nil
            },
            set: { newValue in
                guard newValue == nil, let prompt = sessionManager.tmuxAttachPrompt else { return }
                if serverSessions.contains(where: { $0.id == prompt.id }) {
                    sessionManager.cancelTmuxAttachPrompt(sessionId: prompt.id)
                }
            }
        )
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        let fallback = colorScheme == .dark ? Color.black : Color(UIColor.systemBackground)
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)
            await MainActor.run {
                terminalBackgroundColor = resolved ?? fallback
            }
        }
    }

    private func attemptForegroundReconnectIfNeeded() {
        guard autoReconnectEnabled else { return }
        guard selectedView == "terminal" else { return }
        guard let session = selectedSession else { return }

        switch session.connectionState {
        case .disconnected, .failed:
            Task { try? await sessionManager.reconnect(session: session) }
            reconnectTokenBySession[session.id] = UUID()
            shouldShowTerminalBySession[session.id] = true
        default:
            break
        }
    }

    var body: some View {
        alertContent
            .onAppear {
                updateTerminalBackgroundColor()
                if currentServerId == nil {
                    currentServerId = connectingServer?.id ?? sessionManager.selectedSession?.serverId
                }
                if currentServerId != nil,
                   let selectedId = sessionManager.selectedSessionId,
                   !serverSessions.contains(where: { $0.id == selectedId }),
                   let fallbackId = serverSessions.first?.id {
                    sessionManager.selectedSessionId = fallbackId
                }
            }
            .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
            .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
            .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
            .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    updateTerminalBackgroundColor()
                    // Refresh active terminal when returning from background
                    if selectedView == "terminal",
                       let session = selectedSession {
                        refreshTerminal(for: session)
                    }
                    attemptForegroundReconnectIfNeeded()
                }
            }
            .onChange(of: connectingServer?.id) { newValue in
                guard let newValue else { return }
                currentServerId = newValue
            }
            .onChange(of: sessionManager.selectedSessionId) { newValue in
                guard let newValue,
                      let session = sessionManager.sessions.first(where: { $0.id == newValue }) else { return }
                if currentServerId != session.serverId {
                    currentServerId = session.serverId
                }
            }
            .onChange(of: selectedView) { newValue in
                if newValue != "terminal" {
                    dismissKeyboardForCurrentSession()
                }
            }
            .onChange(of: sessionManager.sessions) { _ in
                if currentServerId == nil, let selected = sessionManager.selectedSession {
                    currentServerId = selected.serverId
                }
                let activeIds = Set(serverSessions.map { $0.id })
                shouldShowTerminalBySession = shouldShowTerminalBySession.filter { activeIds.contains($0.key) }
                reconnectTokenBySession = reconnectTokenBySession.filter { activeIds.contains($0.key) }
                if currentServerId != nil,
                   let selectedId = sessionManager.selectedSessionId,
                   !serverSessions.contains(where: { $0.id == selectedId }),
                   let fallbackId = serverSessions.first?.id {
                    sessionManager.selectedSessionId = fallbackId
                }
                if selectedView == "terminal",
                   let selectedId = effectiveSelectedSessionId,
                   let session = serverSessions.first(where: { $0.id == selectedId }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        refreshTerminal(for: session)
                        focusTerminal(for: session)
                    }
                }
            }
    }

    private var baseContent: some View {
        mainContent
            .background(backgroundView)
            .overlay(alignment: .top) {
                if selectedView == "terminal" {
                    NavBarBackdrop(color: terminalBackgroundColor)
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar { navigationToolbar }
    }

    private var sheetContent: some View {
        baseContent
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .sheet(item: $serverToEdit) { server in
                NavigationStack {
                    ServerFormSheet(
                        serverManager: serverManager,
                        workspace: serverManager.workspaces.first { $0.id == server.workspaceId },
                        server: server,
                        onSave: { _ in serverToEdit = nil }
                    )
                }
            }
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        sessionManager.resolveTmuxAttachPrompt(sessionId: prompt.id, selection: selection)
                    }
                )
            }
    }

    private var alertContent: some View {
        sheetContent
            .alert(String(localized: "Close Tab?"), isPresented: isCloseAlertPresented, presenting: pendingCloseSession) { session in
                Button("Close", role: .destructive) {
                    sessionManager.closeSession(session)
                    pendingCloseSession = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCloseSession = nil
                }
            } message: { session in
                Text(String(format: String(localized: "This will disconnect \"%@\"."), session.title))
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerTabsBar
            sessionContent
        }
    }

    @ViewBuilder
    private var headerTabsBar: some View {
        if selectedView == "terminal" && serverSessions.count > 1 {
            iOSTerminalTabsBar(
                sessions: serverSessions,
                selectedSessionId: selectedSessionIdBinding,
                onClose: { pendingCloseSession = $0 }
            )
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if serverSessions.isEmpty {
            emptyStateContent
        } else {
            activeSessionsContent
        }
    }

    @ViewBuilder
    private var emptyStateContent: some View {
        if isConnecting, let serverName = (connectingServer ?? selectedServer)?.name {
            connectingStateView(serverName: serverName)
        } else if selectedView == "terminal" {
            TerminalEmptyStateView(server: selectedServer) {
                openNewTab()
            }
        } else if let server = selectedServer {
            ServerStatsView(
                server: server,
                isVisible: true,
                sharedClientProvider: { sessionManager.sharedStatsClient(for: server.id) }
            )
        }
    }

    private var activeSessionsContent: some View {
        ZStack {
            if selectedView == "stats", let server = selectedServer {
                ServerStatsView(
                    server: server,
                    isVisible: true,
                    sharedClientProvider: { sessionManager.sharedStatsClient(for: server.id) }
                )
                .zIndex(1)
            }

            ForEach(serverSessions) { session in
                sessionPage(session)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if selectedView == "terminal" {
            terminalBackgroundColor
                .ignoresSafeArea(.all)
        } else {
            Color(UIColor.systemBackground)
                .ignoresSafeArea(.all)
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismissKeyboardForCurrentSession()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
            }
        }

        ToolbarItem(placement: .principal) {
            if let serverId = selectedSession?.serverId {
                iOSNativeSegmentedPicker(selection: selectedViewBinding(for: serverId))
                    .fixedSize()
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selectedView == "terminal" {
                Button {
                    openNewTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            Menu {
                if let server = selectedServer {
                    Button {
                        serverToEdit = server
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }
                }

                Button(role: .destructive) {
                    disconnectAllSessions()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func dismissKeyboardForCurrentSession() {
        guard let selectedId = effectiveSelectedSessionId,
              let terminal = ConnectionSessionManager.shared.getTerminal(for: selectedId) else { return }
        _ = terminal.resignFirstResponder()
    }

    @ViewBuilder
    private func connectingStateView(serverName: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.1)
            Text(String(format: String(localized: "Connecting to %@..."), serverName))
                .font(.headline)
            Text(String(localized: "Preparing server details..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionPage(_ session: ConnectionSession) -> some View {
        let server = serverManager.servers.first { $0.id == session.serverId }
        let viewSelection = sessionManager.selectedViewByServer[session.serverId] ?? "stats"
        let isSelected = effectiveSelectedSessionId == session.id
        let terminalAlreadyExists = ConnectionSessionManager.shared.getTerminal(for: session.id) != nil
        let shouldShowTerminal = shouldShowTerminalBySession[session.id] ?? false
        let reconnectToken = reconnectTokenBySession[session.id] ?? session.id

        ZStack {
            if shouldShowTerminal || terminalAlreadyExists {
                TerminalContainerView(
                    session: session,
                    server: server,
                    isActive: isSelected && viewSelection == "terminal"
                )
                .id(reconnectToken)
                .opacity(viewSelection == "terminal" ? 1 : 0)
                .allowsHitTesting(viewSelection == "terminal")
            }

            if viewSelection == "terminal" && !shouldShowTerminal && !terminalAlreadyExists {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
            }
        }
        .onAppear {
            guard isSelected else { return }
            prepareTerminal(session: session, viewSelection: viewSelection, terminalAlreadyExists: terminalAlreadyExists)
            if viewSelection == "terminal" {
                focusTerminal(for: session)
            }
        }
        .onChange(of: viewSelection) { newValue in
            guard isSelected else { return }
            if newValue == "terminal" {
                prepareTerminal(session: session, viewSelection: newValue, terminalAlreadyExists: terminalAlreadyExists)
                focusTerminal(for: session)
            }
        }
        .onChange(of: isSelected) { newValue in
            guard newValue else { return }
            prepareTerminal(session: session, viewSelection: viewSelection, terminalAlreadyExists: terminalAlreadyExists)
            if viewSelection == "terminal" {
                focusTerminal(for: session)
            }
        }
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
        .overlay(terminalSwipeOverlay(isEnabled: isSelected && viewSelection == "terminal"))
    }

    private func prepareTerminal(session: ConnectionSession, viewSelection: String, terminalAlreadyExists: Bool) {
        guard viewSelection == "terminal" else { return }
        if terminalAlreadyExists {
            refreshTerminal(for: session)
            return
        }
        if shouldShowTerminalBySession[session.id] == true { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            shouldShowTerminalBySession[session.id] = true
        }
    }

    private func openNewTab() {
        guard let server = selectedServer else { return }
        guard sessionManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }
        Task { try? await sessionManager.openConnection(to: server, forceNew: true) }
    }

    private func disconnectAllSessions() {
        sessionManager.disconnectAll()
        onBack()
    }

    /// Refresh terminal display and trigger server redraw
    private func refreshTerminal(for session: ConnectionSession) {
        guard let terminal = ConnectionSessionManager.shared.getTerminal(for: session.id) else { return }

        // Resume rendering if paused
        terminal.resumeRendering()

        // Force layout + refresh after a brief delay to ensure the view is attached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let container = terminal.superview {
                container.setNeedsLayout()
                container.layoutIfNeeded()

                let targetBounds: CGRect
                if let terminalContainer = container as? TerminalContainerUIView {
                    targetBounds = terminalContainer.availableBoundsForTerminal()
                    terminalContainer.requestRefresh()
                } else {
                    targetBounds = container.bounds
                }

                if targetBounds.width > 0, targetBounds.height > 0 {
                    if terminal.frame != targetBounds {
                        terminal.frame = targetBounds
                    }
                    terminal.sizeDidChange(targetBounds.size)
                }
            }

            terminal.forceRefresh()

            // Send resize to force server to redraw prompt
            if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
               let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                Task {
                    if let size = terminal.terminalSize() {
                        try? await sshClient.resize(cols: Int(size.columns), rows: Int(size.rows), for: shellId)
                    }
                }
            }
        }
    }

    private func focusTerminal(for session: ConnectionSession) {
        guard let terminal = ConnectionSessionManager.shared.getTerminal(for: session.id) else { return }

        let attemptFocus = { [weak terminal] in
            guard let terminal = terminal else { return }
            if terminal.window != nil {
                _ = terminal.becomeFirstResponder()
            }
        }

        DispatchQueue.main.async {
            attemptFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                attemptFocus()
            }
        }
    }


    @ViewBuilder
    private func terminalSwipeOverlay(isEnabled: Bool) -> some View {
        if isEnabled && serverSessions.count > 1 {
            GeometryReader { proxy in
                let edgeWidth: CGFloat = 32
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture())

                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture())
                }
            }
        }
    }

    private func tabSwipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical),
                      abs(horizontal) > 60 else { return }
                if horizontal < 0 {
                    selectNextServerSession()
                } else {
                    selectPreviousServerSession()
                }
            }
    }

    private func selectNextServerSession() {
        guard let currentId = sessionManager.selectedSessionId,
              let index = serverSessions.firstIndex(where: { $0.id == currentId }),
              index < serverSessions.count - 1 else { return }
        sessionManager.selectedSessionId = serverSessions[index + 1].id
        triggerTabSwitchFeedback()
    }

    private func selectPreviousServerSession() {
        guard let currentId = sessionManager.selectedSessionId,
              let index = serverSessions.firstIndex(where: { $0.id == currentId }),
              index > 0 else { return }
        sessionManager.selectedSessionId = serverSessions[index - 1].id
        triggerTabSwitchFeedback()
    }

    private func triggerTabSwitchFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}

#if os(iOS)
private struct iOSNativeSegmentedPicker: UIViewRepresentable {
    @Binding var selection: String

    private let tags = ["stats", "terminal"]
    private let images = ["chart.bar.xaxis", "terminal"]

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: images.compactMap { UIImage(systemName: $0) })
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        control.selectedSegmentIndex = selectedIndex
        control.apportionsSegmentWidthsByContent = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        let targetIndex = selectedIndex
        guard uiView.selectedSegmentIndex != targetIndex else { return }
        UIView.performWithoutAnimation {
            uiView.selectedSegmentIndex = targetIndex
            uiView.layoutIfNeeded()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        uiView.sizeToFit()
        return uiView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, tags: tags)
    }

    private var selectedIndex: Int {
        tags.firstIndex(of: selection) ?? 0
    }

    final class Coordinator: NSObject {
        private var selection: Binding<String>
        private let tags: [String]

        init(selection: Binding<String>, tags: [String]) {
            self.selection = selection
            self.tags = tags
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            let index = sender.selectedSegmentIndex
            guard tags.indices.contains(index) else { return }
            selection.wrappedValue = tags[index]
        }
    }
}
#endif

private struct NavBarBackdrop: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 44
            color
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

// MARK: - iOS Terminal Tabs

struct iOSTerminalTabsBar: View {
    let sessions: [ConnectionSession]
    @Binding var selectedSessionId: UUID?
    let onClose: (ConnectionSession) -> Void
    private let minTabWidth: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let count = max(sessions.count, 1)
            let availableWidth = max(proxy.size.width - TerminalTabBarMetrics.horizontalPadding * 2, 0)
            let totalSpacing = TerminalTabBarMetrics.tabSpacing * CGFloat(max(count - 1, 0))
            let itemWidth = count > 0 ? (availableWidth - totalSpacing) / CGFloat(count) : 0
            let useEqualWidth = itemWidth >= minTabWidth

            Group {
                if useEqualWidth {
                    HStack(spacing: TerminalTabBarMetrics.tabSpacing) {
                        ForEach(sessions) { session in
                            iOSTerminalTabButton(
                                session: session,
                                isSelected: selectedSessionId == session.id,
                                fixedWidth: itemWidth,
                                onSelect: { selectedSessionId = session.id },
                                onClose: { onClose(session) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TerminalTabBarMetrics.horizontalPadding)
                    .padding(.vertical, TerminalTabBarMetrics.barVerticalInset)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TerminalTabBarMetrics.tabSpacing) {
                            ForEach(sessions) { session in
                                iOSTerminalTabButton(
                                    session: session,
                                    isSelected: selectedSessionId == session.id,
                                    fixedWidth: nil,
                                    onSelect: { selectedSessionId = session.id },
                                    onClose: { onClose(session) }
                                )
                                .frame(minWidth: minTabWidth)
                            }
                        }
                        .padding(.horizontal, TerminalTabBarMetrics.horizontalPadding)
                        .padding(.vertical, TerminalTabBarMetrics.barVerticalInset)
                        .animation(nil, value: sessions.map(\.id))
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(height: TerminalTabBarMetrics.barHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(Capsule(style: .continuous))
        .padding(.horizontal, TerminalTabBarMetrics.outerHorizontalPadding)
        .padding(.vertical, 6)
    }
}

private enum TerminalTabBarMetrics {
    static let tabHeight: CGFloat = 36
    static let tabVerticalPadding: CGFloat = 7
    static let barVerticalInset: CGFloat = 4
    static let tabSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 4
    static let outerHorizontalPadding: CGFloat = 12
    static var barHeight: CGFloat { tabHeight + barVerticalInset * 2 }
}

private struct iOSTerminalTabButton: View {
    let session: ConnectionSession
    let isSelected: Bool
    let fixedWidth: CGFloat?
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 36)
        .padding(.vertical, TerminalTabBarMetrics.tabVerticalPadding)
        .frame(height: TerminalTabBarMetrics.tabHeight)
        .frame(width: fixedWidth, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            isSelected ? Color.primary.opacity(0.18) : Color.clear,
            in: Capsule(style: .continuous)
        )
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isSelected ? 0.12 : 0.08))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }
}
#endif
