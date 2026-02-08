import SwiftUI

// MARK: - Server Sidebar View (macOS)

struct ServerSidebarView: View {
    @ObservedObject var serverManager: ServerManager
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedServer: Server?

    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var tabManager = TerminalTabManager.shared

    @State private var showingWorkspaceSwitcher = false
    @State private var showingAddServer = false
    @State private var showingSupport = false
    @State private var showingProUpgrade = false
    @State private var showingServerSearch = false
    @State private var showingEnvironmentFilters = false
    @State private var showingCreateEnvironment = false
    @State private var showingCustomEnvironmentAlert = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var lockedServerAlert: Server?

    @AppStorage("environmentFilters") private var storedEnvironmentFilters: String = ""

    // MARK: - Filter State

    private var selectedEnvironmentIds: Set<UUID> {
        guard !storedEnvironmentFilters.isEmpty else { return [] }
        return Set(storedEnvironmentFilters.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private var allEnvironmentIds: Set<UUID> {
        Set((selectedWorkspace?.environments ?? []).map(\.id))
    }

    private var isEnvironmentFiltering: Bool {
        !selectedEnvironmentIds.isEmpty && selectedEnvironmentIds != allEnvironmentIds
    }

    private var environmentFiltersVisible: Bool {
        showingEnvironmentFilters
    }

    private var serverSearchVisible: Bool {
        showingServerSearch || !searchText.isEmpty
    }

    private func updateEnvironmentFilters(_ ids: Set<UUID>) {
        storedEnvironmentFilters = ids.map(\.uuidString).joined(separator: ",")
    }

    private func toggleEnvironmentFilter(_ env: ServerEnvironment) {
        var ids = selectedEnvironmentIds
        if ids.contains(env.id) {
            ids.remove(env.id)
        } else {
            ids.insert(env.id)
        }
        updateEnvironmentFilters(ids)
    }

    // MARK: - Styling

    private var workspaceRowFill: Color {
        Color.primary.opacity(0.05)
    }

    private var inlineSearchStroke: Color {
        Color.primary.opacity(0.08)
    }

    // MARK: - Computed Properties

    private var serverCount: Int {
        guard let workspace = selectedWorkspace else { return 0 }
        return serverManager.servers.filter { $0.workspaceId == workspace.id }.count
    }

    var filteredServers: [Server] {
        guard let workspace = selectedWorkspace else { return [] }

        var servers = serverManager.servers.filter { $0.workspaceId == workspace.id }

        // Apply environment filter
        if isEnvironmentFiltering {
            servers = servers.filter { selectedEnvironmentIds.contains($0.environment.id) }
        }

        // Apply search
        if !searchText.isEmpty {
            let lowercased = searchText.lowercased()
            servers = servers.filter {
                $0.name.lowercased().contains(lowercased) ||
                $0.host.lowercased().contains(lowercased)
            }
        }

        return servers.sorted { $0.name < $1.name }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Workspace section
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("WORKSPACE")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer(minLength: 8)

                    serverControls
                }
                .padding(.horizontal, 12)

                // Current workspace button
                workspacePicker
                    .padding(.horizontal, 12)
            }
            .padding(.top, 12)
            .padding(.bottom, 4)

            if environmentFiltersVisible {
                environmentFilterInline
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if serverSearchVisible {
                serverSearchInline
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Server list
            if filteredServers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredServers) { server in
                            ServerRow(
                                server: server,
                                isSelected: selectedServer?.id == server.id,
                                onSelect: { selectedServer = server },
                                onEdit: { serverToEdit = $0 },
                                onLockedTap: { lockedServerAlert = server }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
            }

            // Support VVTerm (only when not Pro)
            if !storeManager.isPro {
                supportBanner
            }

            // Footer buttons
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
                    onSave: { updatedWorkspace, _ in
                        selectedWorkspace = updatedWorkspace
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
                    onSave: { updatedWorkspace, _ in
                        selectedWorkspace = updatedWorkspace
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
                        environmentToDelete = nil
                    }
                }
            }
        } message: {
            let name = environmentToDelete?.displayName ?? String(localized: "Custom")
            Text(String(format: String(localized: "Servers in '%@' will be moved to Production."), name))
        }
        .proFeatureAlert(
            title: String(localized: "Custom Environments"),
            message: String(localized: "Upgrade to Pro for custom environments"),
            isPresented: $showingCustomEnvironmentAlert
        )
        .lockedItemAlert(
            .server,
            itemName: lockedServerAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedServerAlert != nil },
                set: { if !$0 { lockedServerAlert = nil } }
            )
        )
    }

    // MARK: - Server Controls (Filter + Search)

    @ViewBuilder
    private var serverControls: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingEnvironmentFilters.toggle()
                }
            } label: {
                Image(systemName: (environmentFiltersVisible || isEnvironmentFiltering)
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle((environmentFiltersVisible || isEnvironmentFiltering) ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Filter servers")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if serverSearchVisible {
                        showingServerSearch = false
                        searchText = ""
                    } else {
                        showingServerSearch = true
                    }
                }
            } label: {
                Image(systemName: serverSearchVisible ? "xmark.circle.fill" : "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(serverSearchVisible ? "Hide search" : "Search servers")
        }
    }

    // MARK: - Workspace Picker

    @ViewBuilder
    private var workspacePicker: some View {
        Button {
            showingWorkspaceSwitcher = true
        } label: {
            HStack(spacing: 12) {
                if let workspace = selectedWorkspace {
                    Circle()
                        .fill(Color.fromHex(workspace.colorHex))
                        .frame(width: 10, height: 10)

                    Text(workspace.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    PillBadge(text: "\(serverCount)", color: .secondary)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                } else {
                    Text("Select Workspace")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(workspaceRowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline Environment Filter

    @ViewBuilder
    private var environmentFilterInline: some View {
        let environments = selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments
        let customEnvs = environments.filter { !$0.isBuiltIn }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    updateEnvironmentFilters(Set(environments.map(\.id)))
                } label: {
                    Label("Select All", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Button {
                    storedEnvironmentFilters = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                // "All Environments" option (no filter)
                Button {
                    storedEnvironmentFilters = ""
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 9, height: 9)
                        Text("All Environments")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !isEnvironmentFiltering {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(!isEnvironmentFiltering ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                // Individual environments
                ForEach(environments) { env in
                    HStack(spacing: 0) {
                        Button {
                            toggleEnvironmentFilter(env)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(env.color)
                                    .frame(width: 9, height: 9)
                                Text(env.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if selectedEnvironmentIds.contains(env.id) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)

                        // Edit/Delete icon for custom environments
                        if !env.isBuiltIn {
                            Menu {
                                Button {
                                    if storeManager.isPro {
                                        editingEnvironment = env
                                    } else {
                                        showingCustomEnvironmentAlert = true
                                    }
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    if storeManager.isPro {
                                        environmentToDelete = env
                                    } else {
                                        showingCustomEnvironmentAlert = true
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedEnvironmentIds.contains(env.id) ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }

                // Divider before custom actions
                Divider()
                    .padding(.vertical, 2)

                // Create custom environment
                Button {
                    if storeManager.isPro {
                        showingCreateEnvironment = true
                    } else {
                        showingCustomEnvironmentAlert = true
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 9, height: 9)
                        Text("Custom...")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !storeManager.isPro {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 10))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(inlineSearchStroke, lineWidth: 0.8)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Inline Search

    @ViewBuilder
    private var serverSearchInline: some View {
        SearchField(
            placeholder: "Search servers...",
            text: $searchText,
            spacing: 8,
            iconSize: 15,
            iconWeight: .regular,
            iconColor: .secondary,
            textFont: .system(size: 14, weight: .medium),
            clearButtonSize: 13,
            clearButtonWeight: .semibold,
            trailing: {
                EmptyView()
            }
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(inlineSearchStroke, lineWidth: 0.8)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Empty States

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if isEnvironmentFiltering {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No servers match the current filters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    storedEnvironmentFilters = ""
                } label: {
                    Text("Clear Filters")
                }
                .buttonStyle(.bordered)
            } else if !searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No servers found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No servers in this workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showingAddServer = true
                } label: {
                    Text("Add Server")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                Text(verbatim: "\u{2022}")
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
    }
}
