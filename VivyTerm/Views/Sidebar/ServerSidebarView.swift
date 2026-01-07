import SwiftUI

// MARK: - Server Sidebar View (macOS)

struct ServerSidebarView: View {
    @ObservedObject var serverManager: ServerManager
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedServer: Server?
    @Binding var selectedEnvironment: ServerEnvironment?

    @ObservedObject private var storeManager = StoreManager.shared

    @State private var showingWorkspaceSwitcher = false
    @State private var showingAddServer = false
    @State private var showingSettings = false
    @State private var showingSupport = false
    @State private var showingProUpgrade = false
    @State private var searchText = ""
    @State private var serverToEdit: Server?

    var body: some View {
        VStack(spacing: 0) {
            // 1. Workspace Section Header
            workspaceSectionHeader

            Divider()

            // 2. Search Field
            searchSection

            Divider()

            // 3. Server List with Environment Header
            serverSection

            Divider()

            // 4. Support VVTerm (only when not Pro)
            if !storeManager.isPro {
                supportBanner
            }

            // 5. Footer Buttons
            footerButtons
        }
        .sheet(isPresented: $showingWorkspaceSwitcher) {
            WorkspaceSwitcherSheet(
                serverManager: serverManager,
                selectedWorkspace: $selectedWorkspace
            )
        }
        .sheet(isPresented: $showingAddServer) {
            ServerFormSheet(
                serverManager: serverManager,
                workspace: selectedWorkspace,
                onSave: { _ in showingAddServer = false }
            )
        }
        .sheet(item: $serverToEdit) { server in
            ServerFormSheet(
                serverManager: serverManager,
                workspace: selectedWorkspace,
                server: server,
                onSave: { _ in serverToEdit = nil }
            )
        }
        .sheet(isPresented: $showingSupport) {
            SupportSheet()
        }
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
        }
    }

    // MARK: - Workspace Section

    private var workspaceSectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORKSPACE")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)

            Button {
                showingWorkspaceSwitcher = true
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.fromHex(selectedWorkspace?.colorHex ?? "#007AFF"))
                        .frame(width: 8, height: 8)

                    Text(selectedWorkspace?.name ?? "Select Workspace")
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    PillBadge(text: "\(serverCount)", color: .secondary)

                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Search Section

    private var searchSection: some View {
        SearchField(placeholder: "Search servers...", text: $searchText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    // MARK: - Server Section

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header with environment menu
            HStack {
                Text("SERVERS")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                EnvironmentMenu(
                    selected: $selectedEnvironment,
                    environments: selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments,
                    serverCounts: serverCountsByEnvironment
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Server list
            List {
                ForEach(filteredServers) { server in
                    ServerRow(
                        server: server,
                        isSelected: selectedServer?.id == server.id,
                        onEdit: { serverToEdit = $0 },
                        onSelect: { selectedServer = server }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Support Banner

    private var supportBanner: some View {
        Button {
            showingProUpgrade = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Upgrade to Pro")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text("Support VVTerm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08))
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        HStack(spacing: 0) {
            Button {
                showingAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Spacer()

            Button {
                showingSupport = true
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .help("Support & Feedback")

            Button {
                #if os(macOS)
                SettingsWindowManager.shared.show()
                #else
                showingSettings = true
                #endif
            } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Settings")
        }
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Computed Properties

    private var serverCount: Int {
        guard let workspace = selectedWorkspace else { return 0 }
        return serverManager.servers.filter { $0.workspaceId == workspace.id }.count
    }

    private var filteredServers: [Server] {
        guard let workspace = selectedWorkspace else { return [] }

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

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let isSelected: Bool
    let onEdit: (Server) -> Void
    let onSelect: () -> Void

    @ObservedObject private var sessionManager = ConnectionSessionManager.shared

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)

                Text(server.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Environment badge
            Text(server.environment.shortName)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(server.environment.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(server.environment.color.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(selectionBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Connect") {
                Task { try? await sessionManager.openConnection(to: server) }
            }
            Button("Edit") {
                onEdit(server)
            }
            Divider()
            Button("Remove", role: .destructive) {
                Task { try? await ServerManager.shared.deleteServer(server) }
            }
        }
    }

    private var statusColor: Color {
        // Check if connected
        let isConnected = sessionManager.sessions.contains { $0.serverId == server.id && $0.connectionState.isConnected }
        return isConnected ? .green : .secondary.opacity(0.3)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
        }
    }
}

// MARK: - Environment Menu

struct EnvironmentMenu: View {
    @Binding var selected: ServerEnvironment?
    let environments: [ServerEnvironment]
    let serverCounts: [UUID: Int]

    @ObservedObject private var storeManager = StoreManager.shared
    @State private var showingProUpgrade = false

    private var totalCount: Int {
        serverCounts.values.reduce(0, +)
    }

    var body: some View {
        Menu {
            // Built-in environments
            ForEach(ServerEnvironment.builtInEnvironments) { env in
                environmentButton(env)
            }

            // Custom environments (Pro users only see these)
            let customEnvs = environments.filter { !$0.isBuiltIn }
            if !customEnvs.isEmpty {
                Divider()
                ForEach(customEnvs) { env in
                    environmentButton(env)
                }
            }

            Divider()

            // All filter
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

            // Create custom (Pro only)
            Button {
                if storeManager.isPro {
                    // Show create custom environment
                } else {
                    showingProUpgrade = true
                }
            } label: {
                HStack {
                    Label("Custom...", systemImage: "plus")
                    Spacer()
                    if !storeManager.isPro {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(selected?.shortName ?? "All")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
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
                Text(env.name)
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

// MARK: - Pill Badge

struct PillBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Search Field

struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Workspace Switcher Sheet

struct WorkspaceSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverManager: ServerManager
    @Binding var selectedWorkspace: Workspace?

    @State private var hoveredWorkspace: Workspace?
    @State private var showingCreateWorkspace = false
    @State private var workspaceToEdit: Workspace?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            DetailHeaderBar(
                showsBackground: false,
                padding: EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20)
            ) {
                Text("Workspaces")
                    .font(.title2)
                    .fontWeight(.semibold)
            } trailing: {
                DetailCloseButton { dismiss() }
            }

            Divider()

            // Workspace list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(serverManager.workspaces) { workspace in
                        WorkspaceSwitcherRow(
                            workspace: workspace,
                            isSelected: selectedWorkspace?.id == workspace.id,
                            isHovered: hoveredWorkspace?.id == workspace.id,
                            serverCount: serverCount(for: workspace),
                            onSelect: {
                                selectedWorkspace = workspace
                                dismiss()
                            },
                            onEdit: {
                                workspaceToEdit = workspace
                            }
                        )
                        .onHover { hovering in
                            hoveredWorkspace = hovering ? workspace : nil
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // Footer with new workspace button
            HStack {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Label("New Workspace", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 400, height: 500)
        .sheet(isPresented: $showingCreateWorkspace) {
            WorkspaceFormSheet(
                serverManager: serverManager,
                onSave: { newWorkspace in
                    selectedWorkspace = newWorkspace
                }
            )
        }
        .sheet(item: $workspaceToEdit) { workspace in
            WorkspaceFormSheet(
                serverManager: serverManager,
                workspace: workspace,
                onSave: { updatedWorkspace in
                    if selectedWorkspace?.id == updatedWorkspace.id {
                        selectedWorkspace = updatedWorkspace
                    }
                }
            )
        }
    }

    private func serverCount(for workspace: Workspace) -> Int {
        serverManager.servers.filter { $0.workspaceId == workspace.id }.count
    }
}

// MARK: - Workspace Switcher Row

struct WorkspaceSwitcherRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isHovered: Bool
    let serverCount: Int
    let onSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon or color indicator
            Circle()
                .fill(Color.fromHex(workspace.colorHex))
                .frame(width: 8, height: 8)

            Text(workspace.name)
                .font(.body)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            PillBadge(text: "\(serverCount)", color: .secondary)

            if isHovered || isSelected {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Switch to Workspace", systemImage: "arrow.right.circle")
            }

            Divider()

            Button {
                onEdit()
            } label: {
                Label("Edit Workspace", systemImage: "pencil")
            }

            Button(role: .destructive) {
                Task {
                    try? await ServerManager.shared.deleteWorkspace(workspace)
                }
            } label: {
                Label("Delete Workspace", systemImage: "trash")
            }
        }
    }
}
