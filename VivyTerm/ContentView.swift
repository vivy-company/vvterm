//
//  ContentView.swift
//  VivyTerm
//

import SwiftUI

struct ContentView: View {
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var sessionManager = ConnectionSessionManager.shared
    @StateObject private var storeManager = StoreManager.shared

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Server we're connected to (from connectedServerId)
    private var connectedServer: Server? {
        guard let id = sessionManager.connectedServerId else { return nil }
        return serverManager.servers.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // LEFT: Sidebar with workspace + servers
            ServerSidebarView(
                serverManager: serverManager,
                selectedWorkspace: $selectedWorkspace,
                selectedServer: $selectedServer,
                selectedEnvironment: $selectedEnvironment
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            // RIGHT: Terminal with toolbar tabs
            if sessionManager.connectedServerId != nil {
                // Connected to a server - show terminal container (handles empty state internally)
                ConnectionTerminalContainer(
                    sessionManager: sessionManager,
                    serverManager: serverManager,
                    selectedServer: selectedServer ?? connectedServer
                )
            } else if let server = selectedServer {
                // Not connected - show connect button
                ServerConnectEmptyState(server: server) {
                    Task { try? await sessionManager.openConnection(to: server) }
                }
            } else {
                NoServerSelectedEmptyState()
            }
        }
        .onAppear {
            // Select first workspace
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
        .onChange(of: serverManager.workspaces) { _, workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        .onChange(of: selectedServer) { _, server in
            // Auto-connect on selection (optional)
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
    }
}

// MARK: - iOS Specific Content View

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
    @State private var showingSupport = false
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
                HStack(spacing: 16) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }

                    Button {
                        showingSupport = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
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
        .sheet(isPresented: $showingSupport) {
            NavigationStack {
                SupportSheet()
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

// MARK: - iOS Server Row

struct iOSServerRow: View {
    let server: Server
    let onTap: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Server icon
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                // Server info
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body)
                        .fontWeight(.medium)

                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                onTap()
            } label: {
                Label("Connect", systemImage: "play.fill")
            }

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }
}

// MARK: - iOS Active Connection Row

struct iOSActiveConnectionRow: View {
    let session: ConnectionSession
    let onOpen: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                // Connection info
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(session.connectionState.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDisconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
}

// MARK: - iOS Workspace Picker View

struct iOSWorkspacePickerView: View {
    @ObservedObject var serverManager: ServerManager
    @Binding var selectedWorkspace: Workspace?
    let onDismiss: () -> Void

    var body: some View {
        List {
            ForEach(serverManager.workspaces) { workspace in
                Button {
                    selectedWorkspace = workspace
                    onDismiss()
                } label: {
                    HStack {
                        Circle()
                            .fill(Color.fromHex(workspace.colorHex ?? "#007AFF"))
                            .frame(width: 12, height: 12)

                        Text(workspace.name)
                            .foregroundStyle(.primary)

                        Spacer()

                        if selectedWorkspace?.id == workspace.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }

                        Text("\(serverManager.servers(in: workspace, environment: nil).count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss() }
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

// MARK: - Connection State Description

extension ConnectionState {
    var description: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .disconnected, .idle: return "Disconnected"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}
#endif

// MARK: - Empty State Views

struct ServerConnectEmptyState: View {
    let server: Server
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onConnect) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                    Text("Connect")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoServerSelectedEmptyState: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "arrow.left.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("Select a Server")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Choose a server from the sidebar to connect")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoServersEmptyState: View {
    let onAddServer: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("No Servers")
                        .font(.headline)
                        .fontWeight(.semibold)

                    Text("Add a server to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onAddServer) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Server")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
