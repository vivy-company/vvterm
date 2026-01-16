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
    @State private var showingCustomEnvironmentAlert = false
    @State private var showingCreateEnvironment = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var lockedServerAlert: Server?

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

                    Text(selectedWorkspace?.name ?? String(localized: "Select Workspace"))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Server list
            List {
                ForEach(filteredServers) { server in
                    ServerRow(
                        server: server,
                        isSelected: selectedServer?.id == server.id,
                        onEdit: { serverToEdit = $0 },
                        onSelect: { selectedServer = server },
                        onLockedTap: { lockedServerAlert = server }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
                    Text(verbatim: "•")
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
            .help(Text("Support & Feedback"))

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
            .help(Text("Settings"))
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

// MARK: - Environment Menu

struct EnvironmentMenu: View {
    @Binding var selected: ServerEnvironment?
    let environments: [ServerEnvironment]
    let serverCounts: [UUID: Int]
    let onCreateCustom: () -> Void
    let onEditCustom: (ServerEnvironment) -> Void
    let onDeleteCustom: (ServerEnvironment) -> Void

    @ObservedObject private var storeManager = StoreManager.shared

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
                    Text(String(format: String(localized: "(%lld)"), Int64(totalCount)))
                        .foregroundStyle(.secondary)
                    if selected == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Create custom (Pro only)
            Button {
                onCreateCustom()
            } label: {
                HStack {
                    Label(String(localized: "Custom..."), systemImage: "plus")
                    Spacer()
                    if !storeManager.isPro {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                    }
                }
            }

            if let selectedEnvironment = selected, !selectedEnvironment.isBuiltIn {
                Divider()

                Button {
                    onEditCustom(selectedEnvironment)
                } label: {
                    HStack {
                        Label(
                            String(format: String(localized: "Edit \"%@\"..."), selectedEnvironment.displayName),
                            systemImage: "pencil"
                        )
                        Spacer()
                        if !storeManager.isPro {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                        }
                    }
                }

                Button(role: .destructive) {
                    onDeleteCustom(selectedEnvironment)
                } label: {
                    HStack {
                        Label(
                            String(format: String(localized: "Delete \"%@\"..."), selectedEnvironment.displayName),
                            systemImage: "trash"
                        )
                        Spacer()
                        if !storeManager.isPro {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(selected?.displayShortName ?? String(localized: "All"))
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
