//
//  iOSContentView.swift
//  VivyTerm
//

import SwiftUI

#if os(iOS)
struct iOSContentView: View {
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var sessionManager = ConnectionSessionManager.shared

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var showingTerminal = false
    @State private var showingProUpgrade = false
    @State private var lockedServerName: String?

    var body: some View {
        NavigationStack {
            iOSServerListView(
                serverManager: serverManager,
                sessionManager: sessionManager,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                showingTerminal: $showingTerminal,
                showingProUpgrade: $showingProUpgrade,
                onServerSelected: { server in
                    selectedServer = server
                    Task {
                        do {
                            _ = try await sessionManager.openConnection(to: server)
                            showingTerminal = true
                        } catch let error as VivyTermError {
                            switch error {
                            case .proRequired:
                                showingProUpgrade = true
                            case .serverLocked(let name):
                                lockedServerName = name
                            default:
                                break
                            }
                        } catch {
                            // Handle other errors if needed
                        }
                    }
                }
            )
            .navigationDestination(isPresented: $showingTerminal) {
                if let session = sessionManager.selectedSession {
                    iOSTerminalView(
                        session: session,
                        server: serverManager.servers.first { $0.id == session.serverId },
                        onBack: { showingTerminal = false }
                    )
                }
            }
        }
        .onAppear {
            // Select first workspace on appear
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
        .onChange(of: serverManager.workspaces) { _, workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        // Sync navigation state with session state - dismiss terminal if session is gone
        .onChange(of: sessionManager.sessions) { _, sessions in
            if showingTerminal && sessionManager.selectedSession == nil {
                showingTerminal = false
            }
        }
        .onChange(of: sessionManager.selectedSessionId) { _, selectedId in
            if showingTerminal && selectedId == nil {
                showingTerminal = false
            }
        }
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
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
}

struct iOSServerListView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    @Binding var showingTerminal: Bool
    @Binding var showingProUpgrade: Bool
    let onServerSelected: (Server) -> Void

    @ObservedObject private var storeManager = StoreManager.shared

    @State private var showingAddServer = false
    @State private var showingAddWorkspace = false
    @State private var showingSettings = false
    @State private var showingWorkspacePicker = false
    @State private var showingCreateEnvironment = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var lockedServerAlert: Server?

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

                        Text("\(filteredServers.count) servers")
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
                    NoServersEmptyState {
                        showingAddServer = true
                    }
                    .listRowBackground(Color.clear)
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
                                    showingProUpgrade = true
                                }
                            },
                            onEditCustom: { environment in
                                if storeManager.isPro {
                                    editingEnvironment = environment
                                } else {
                                    showingProUpgrade = true
                                }
                            },
                            onDeleteCustom: { environment in
                                if storeManager.isPro {
                                    environmentToDelete = environment
                                } else {
                                    showingProUpgrade = true
                                }
                            }
                        )
                    }
                }
            }

            // Active Connections Section
            if !sessionManager.sessions.isEmpty {
                Section {
                    ForEach(sessionManager.sessions, id: \.id) { session in
                        iOSActiveConnectionRow(
                            session: session,
                            onOpen: {
                                sessionManager.selectSession(session)
                                showingTerminal = true
                            },
                            onDisconnect: {
                                sessionManager.closeSession(session)
                            }
                        )
                    }
                } header: {
                    Text("Active Connections")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search servers")
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAddServer = true
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
        .sheet(isPresented: $showingAddServer) {
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    onSave: { _ in showingAddServer = false }
                )
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
    }

    private var environmentOptions: [ServerEnvironment] {
        selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments
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
                    Text("(\(totalCount))")
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
                Text("(\(serverCounts[env.id] ?? 0))")
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
    let session: ConnectionSession
    let server: Server?
    let onBack: () -> Void

    @State private var selectedView: String = "stats"
    /// Delayed flag to allow tab animation to complete before creating terminal
    @State private var shouldShowTerminal = false

    /// Check if terminal already exists (was previously created)
    private var terminalAlreadyExists: Bool {
        ConnectionSessionManager.shared.getTerminal(for: session.id) != nil
    }

    var body: some View {
        ZStack {
            // Terminal view - only create after delay to not block tab animation
            if shouldShowTerminal || terminalAlreadyExists {
                TerminalContainerView(session: session, server: server, isActive: selectedView == "terminal")
                    .opacity(selectedView == "terminal" ? 1 : 0)
                    .allowsHitTesting(selectedView == "terminal")
            }

            // Stats view
            if let server = server {
                ServerStatsView(server: server, isVisible: selectedView == "stats")
                    .opacity(selectedView == "stats" ? 1 : 0)
                    .allowsHitTesting(selectedView == "stats")
            }

            // Loading indicator when switching to terminal for the first time
            if selectedView == "terminal" && !shouldShowTerminal && !terminalAlreadyExists {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
            }
        }
        .onChange(of: selectedView) { _, newValue in
            if newValue == "terminal" {
                if !shouldShowTerminal && !terminalAlreadyExists {
                    // Delay terminal creation to allow tab animation to complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        shouldShowTerminal = true
                    }
                } else {
                    // Terminal already exists - refresh it when switching back
                    refreshTerminal()
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }

            ToolbarItem(placement: .principal) {
                Picker("View", selection: $selectedView) {
                    Image(systemName: "chart.bar.xaxis")
                        .tag("stats")
                    Image(systemName: "terminal")
                        .tag("terminal")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    ConnectionSessionManager.shared.disconnectAll()
                    onBack()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
    }

    /// Refresh terminal display and trigger server redraw
    private func refreshTerminal() {
        guard let terminal = ConnectionSessionManager.shared.getTerminal(for: session.id) else { return }

        // Resume rendering if paused
        terminal.resumeRendering()

        // Force refresh display
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminal.forceRefresh()

            // Send resize to force server to redraw prompt
            if let sshClient = ConnectionSessionManager.shared.sshClient(for: session) {
                Task {
                    if let size = await terminal.terminalSize() {
                        try? await sshClient.resize(cols: Int(size.columns), rows: Int(size.rows))
                    }
                }
            }
        }
    }
}
#endif
