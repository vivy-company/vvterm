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

    var body: some View {
        NavigationStack {
            iOSServerListView(
                serverManager: serverManager,
                sessionManager: sessionManager,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                showingTerminal: $showingTerminal,
                onServerSelected: { server in
                    selectedServer = server
                    Task {
                        try? await sessionManager.openConnection(to: server)
                        showingTerminal = true
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
    }
}

struct iOSServerListView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    @Binding var showingTerminal: Bool
    let onServerSelected: (Server) -> Void

    @State private var showingAddServer = false
    @State private var showingAddWorkspace = false
    @State private var showingSettings = false
    @State private var showingWorkspacePicker = false
    @State private var searchText = ""
    @State private var serverToEdit: Server?

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

                        Text(selectedWorkspace?.name ?? "Select Workspace")
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
                            onEdit: { serverToEdit = server }
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let server = filteredServers[index]
                            Task { try? await serverManager.deleteServer(server) }
                        }
                    }
                }
            } header: {
                Text("Servers")
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
            NavigationStack {
                SettingsView()
            }
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
}

// MARK: - iOS Terminal View

struct iOSTerminalView: View {
    let session: ConnectionSession
    let server: Server?
    let onBack: () -> Void

    @State private var selectedView: String = "stats"

    var body: some View {
        ZStack {
            // Terminal view
            TerminalContainerView(session: session, server: server)
                .opacity(selectedView == "terminal" ? 1 : 0)
                .allowsHitTesting(selectedView == "terminal")

            // Stats view
            if let server = server {
                ServerStatsView(server: server, session: session)
                    .opacity(selectedView == "stats" ? 1 : 0)
                    .allowsHitTesting(selectedView == "stats")
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
}
#endif
