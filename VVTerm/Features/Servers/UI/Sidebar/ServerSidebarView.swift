import SwiftUI

// MARK: - Server Sidebar View (macOS)

struct ServerSidebarView: View {
    let serverManager: ServerManager
    let serverFormDependencies: ServerFormDependencies
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    let onOpenSettings: () -> Void
    @ObservedObject private var stateStore: ServerStateStore
    @ObservedObject private var workspaceSelectionStore: WorkspaceSelectionStore
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedServer: Server?

    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var appLockManager: AppLockManager
    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager
    private let tabManager: TerminalTabManager
    @ObservedObject private var terminalNavigation: TerminalSessionNavigationProjection
    #if os(macOS)
    @EnvironmentObject private var commandBridge: MacShellCommandBridge
    #endif

    @State private var showingWorkspaceSwitcher = false
    @State private var showingAddServer = false
    @State private var localDiscoveryPresentation: LocalDeviceDiscoveryPresentation?
    @State private var showingSupport = false
    @State private var showingProUpgrade = false
    @State private var showingServerSearch = false
    @State private var showingEnvironmentFilters = false
    @State private var showingCreateEnvironment = false
    @State private var showingCustomEnvironmentAlert = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var environmentDeletionError: String?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var serverToMove: Server?
    @State private var lockedServerAlert: Server?
    @State private var addServerPrefill: ServerFormPrefill?
    @State private var queuedDiscoveryPrefill: ServerFormPrefill?

    init(
        serverManager: ServerManager,
        tabManager: TerminalTabManager,
        terminalNavigation: TerminalSessionNavigationProjection,
        serverFormDependencies: ServerFormDependencies,
        workspaceSelectionStore: WorkspaceSelectionStore,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        onOpenSettings: @escaping () -> Void,
        selectedWorkspace: Binding<Workspace?>,
        selectedServer: Binding<Server?>
    ) {
        self.serverManager = serverManager
        self.serverFormDependencies = serverFormDependencies
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.onOpenSettings = onOpenSettings
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        _workspaceSelectionStore = ObservedObject(
            wrappedValue: workspaceSelectionStore
        )
        self.tabManager = tabManager
        _terminalNavigation = ObservedObject(wrappedValue: terminalNavigation)
        _selectedWorkspace = selectedWorkspace
        _selectedServer = selectedServer
    }

    // MARK: - Filter State

    private var canAddServer: Bool {
        !stateStore.workspaces.isEmpty
    }

    private var selectedEnvironmentIds: Set<UUID> {
        workspaceSelectionStore.environmentFilterIDs(for: selectedWorkspace)
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
        workspaceSelectionStore.updateEnvironmentFilterIDs(
            ids,
            for: selectedWorkspace
        )
    }

    private func reconcileEnvironmentFilters() {
        workspaceSelectionStore.reconcile(
            workspaces: stateStore.workspaces,
            legacyMigrationWorkspace: selectedWorkspace
        )
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
        return stateStore.servers.filter { $0.workspaceId == workspace.id }.count
    }

    var filteredServers: [Server] {
        guard let workspace = selectedWorkspace else { return [] }

        var servers = stateStore.servers.filter { $0.workspaceId == workspace.id }

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

            ServerLocalStorageNotice(serverManager: serverManager)

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
                                serverManager: serverManager,
                                terminalNavigation: terminalNavigation,
                                server: server,
                                isSelected: selectedServer?.id == server.id,
                                isLocked: stateStore.isServerLocked(
                                    server,
                                    hasProAccess: storeManager.allowsProFeatures
                                ),
                                onSelect: { selectServer(server) },
                                onEdit: { serverToEdit = $0 },
                                onMove: { serverToMove = $0 },
                                onConnect: { connectToServer($0) },
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
            if !storeManager.allowsProFeatures {
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
            .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingAddServer) {
            ServerFormSheet(
                serverManager: serverManager,
                workspace: selectedWorkspace,
                prefill: addServerPrefill,
                dependencies: serverFormDependencies,
                makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                onSave: { _ in showingAddServer = false }
            )
            .adaptiveSoftScrollEdges()
            #if os(macOS)
            .frame(
                minWidth: 640,
                idealWidth: 700,
                maxWidth: 760,
                minHeight: 520,
                idealHeight: 620,
                maxHeight: 680
            )
            #endif
        }
        .sheet(item: $localDiscoveryPresentation, onDismiss: resumeDiscoveredServerCreation) { presentation in
            LocalDeviceDiscoverySheet(manager: presentation.manager) { discoveredHost in
                queuedDiscoveryPrefill = ServerFormPrefill(discoveredHost: discoveredHost)
            }
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $serverToEdit) { server in
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
            .adaptiveSoftScrollEdges()
            #if os(macOS)
            .frame(
                minWidth: 640,
                idealWidth: 700,
                maxWidth: 760,
                minHeight: 520,
                idealHeight: 620,
                maxHeight: 680
            )
            #endif
        }
        .sheet(item: $serverToMove) { server in
            MoveServerSheet(
                serverManager: serverManager,
                server: server,
                onMove: { updatedServer in
                    handleSavedServer(updatedServer, originalServer: server)
                    serverToMove = nil
                }
            )
            .adaptiveSoftScrollEdges()
            #if os(macOS)
            .frame(
                minWidth: 520,
                idealWidth: 560,
                maxWidth: 620,
                minHeight: 360,
                idealHeight: 420,
                maxHeight: 520
            )
            #endif
        }
        .sheet(isPresented: $showingSupport) {
            SupportSheet()
                .adaptiveSoftScrollEdges()
        }
        .proUpgradePresentation(isPresented: $showingProUpgrade, source: .sidebarBanner)
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
                .adaptiveSoftScrollEdges()
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
                        selectedServer = WorkspaceSelectionPolicy.server(
                            current: selectedServer,
                            available: serverManager.servers
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
        .proFeatureAlert(
            title: String(localized: "Custom Environments"),
            message: String(localized: "Upgrade to Pro for custom environments"),
            source: .customEnvironment,
            isPresented: $showingCustomEnvironmentAlert
        )
        .onChange(of: selectedWorkspace?.id) { _ in
            reconcileEnvironmentFilters()
            guard showingWorkspaceSwitcher else { return }
            dismissWorkspacePickerForPendingPrefilledAddServerIfNeeded()
        }
        .onChange(of: stateStore.workspaces) { _ in
            reconcileEnvironmentFilters()
        }
        .onAppear {
            reconcileEnvironmentFilters()
        }
        .onChange(of: showingWorkspaceSwitcher) { isPresented in
            guard !isPresented else { return }
            resumePendingPrefilledAddServerIfNeeded()
        }
        .onChange(of: showingAddServer) { isPresented in
            if !isPresented {
                addServerPrefill = nil
            }
        }
        #if os(macOS)
        .focusedValue(\.openLocalSSHDiscovery, {
            presentLocalDiscovery()
        })
        // The sidebar is hosted in its own NSHostingController, so the
        // focusedValue above can't reach the scene Commands. Register the action
        // on the shell command bridge too; ContentView republishes it.
        .onAppear {
            commandBridge.setLocalDiscovery(presentLocalDiscovery)
        }
        .onDisappear {
            commandBridge.setLocalDiscovery(nil)
        }
        #endif
        .lockedItemAlert(
            .server,
            itemName: lockedServerAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedServerAlert != nil },
                set: { if !$0 { lockedServerAlert = nil } }
            )
        )
    }

    private func presentLocalDiscovery() {
        guard localDiscoveryPresentation == nil else { return }
        localDiscoveryPresentation = LocalDeviceDiscoveryPresentation(
            makeManager: makeLocalDiscoveryManager
        )
    }

    private func resumeDiscoveredServerCreation() {
        guard let queued = queuedDiscoveryPrefill else { return }
        queuedDiscoveryPrefill = nil
        presentAddServer(prefill: queued)
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
            .help(serverSearchVisible ? String(localized: "Hide search") : String(localized: "Search servers"))
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
                    updateEnvironmentFilters([])
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
                    updateEnvironmentFilters([])
                } label: {
                    HStack(spacing: 7) {
                        if !isEnvironmentFiltering {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 9, height: 9)
                        } else {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 9, height: 9)
                        }
                        Text("All Environments")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                // Individual environments
                ForEach(environments) { env in
                    let isChecked = selectedEnvironmentIds.contains(env.id)
                    HStack(spacing: 0) {
                        Button {
                            toggleEnvironmentFilter(env)
                        } label: {
                            HStack(spacing: 7) {
                                if isChecked {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(env.color)
                                        .frame(width: 9, height: 9)
                                } else {
                                    Circle()
                                        .fill(env.color)
                                        .frame(width: 9, height: 9)
                                }
                                Text(env.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)

                        // Edit/Delete icon for custom environments
                        if !env.isBuiltIn {
                            Menu {
                                Button {
                                    if storeManager.allowsProFeatures {
                                        editingEnvironment = env
                                    } else {
                                        showingCustomEnvironmentAlert = true
                                    }
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    if storeManager.allowsProFeatures {
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
                }

                // Divider before custom actions
                Divider()
                    .padding(.vertical, 2)

                // Create custom environment
                Button {
                    if storeManager.allowsProFeatures {
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
                        if !storeManager.allowsProFeatures {
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

    private func selectServer(_ server: Server) {
        Task { @MainActor in
            guard await appLockManager.ensureServerUnlocked(server) else { return }
            selectedServer = server
        }
    }

    private func connectToServer(_ server: Server) {
        Task {
            guard await appLockManager.ensureServerUnlocked(server) else { return }
            do {
                let tab = try await tabManager.openTab(for: server)
                await MainActor.run {
                    selectedServer = server
                    tabManager.sessionState.selectView(
                        viewTabConfig.effectiveDefaultTab(),
                        for: server.id
                    )
                    tabManager.sessionState.selectTab(tab.id, for: server.id)
                }
            } catch {
                // No-op: user cancelled biometric auth or the tab limit blocked the open.
            }
        }
    }

    private func handleSavedServer(_ server: Server, originalServer: Server) {
        let movedAcrossWorkspaces = originalServer.workspaceId != server.workspaceId

        if movedAcrossWorkspaces,
           let destinationWorkspace = stateStore.workspace(withID: server.workspaceId) {
            selectedWorkspace = destinationWorkspace
            selectedServer = server
            return
        }

        if isEnvironmentFiltering && !selectedEnvironmentIds.contains(server.environment.id) {
            updateEnvironmentFilters([])
        }

        if selectedServer?.id == server.id {
            selectedServer = server
        }
    }

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
                    updateEnvironmentFilters([])
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
            } else if stateStore.workspaces.isEmpty {
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No workspaces available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showingWorkspaceSwitcher = true
                } label: {
                    Text("Create Workspace")
                }
                .buttonStyle(.bordered)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No servers in this workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    presentAddServer()
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
                presentAddServer()
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(!canAddServer)
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
                onOpenSettings()
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

    private func presentAddServer(prefill: ServerFormPrefill? = nil) {
        addServerPrefill = prefill
        switch ServerCreationPresentationPolicy.initialStep(canAddServer: canAddServer) {
        case .createWorkspace:
            showingWorkspaceSwitcher = true
        case .createServer:
            showingAddServer = true
        }
    }

    private func dismissWorkspacePickerForPendingPrefilledAddServerIfNeeded() {
        guard addServerPrefill != nil, canAddServer else { return }
        showingWorkspaceSwitcher = false
    }

    private func resumePendingPrefilledAddServerIfNeeded() {
        guard ServerCreationPresentationPolicy.shouldResumePrefilledServer(
            hasPrefill: addServerPrefill != nil,
            canAddServer: canAddServer,
            isPresentingServer: showingAddServer
        ) else { return }
        showingAddServer = true
    }
}
