import SwiftUI

// MARK: - Workspace Switcher Sheet

struct WorkspaceSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeManager: StoreManager
    let serverManager: ServerManager
    @ObservedObject private var stateStore: ServerStateStore
    @Binding var selectedWorkspace: Workspace?

    @State private var hoveredWorkspace: Workspace?
    @State private var showingCreateWorkspace = false
    @State private var workspaceToEdit: Workspace?
    @State private var workspaceToDelete: Workspace?
    @State private var workspaceToManageServers: Workspace?
    @State private var lockedWorkspaceAlert: Workspace?

    init(
        serverManager: ServerManager,
        selectedWorkspace: Binding<Workspace?>
    ) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        _selectedWorkspace = selectedWorkspace
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Workspaces") {
                dismiss()
            }

            Divider()

            // Workspace list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(stateStore.workspaces) { workspace in
                        WorkspaceSwitcherRow(
                            workspace: workspace,
                            isSelected: selectedWorkspace?.id == workspace.id,
                            isHovered: hoveredWorkspace?.id == workspace.id,
                            isLocked: stateStore.isWorkspaceLocked(
                                workspace,
                                hasProAccess: storeManager.allowsProFeatures
                            ),
                            serverCount: serverCount(for: workspace),
                            onSelect: {
                                selectedWorkspace = workspace
                                dismiss()
                            },
                            onEdit: {
                                workspaceToEdit = workspace
                            },
                            onLockedTap: {
                                lockedWorkspaceAlert = workspace
                            },
                            onManageServers: {
                                workspaceToManageServers = workspace
                            },
                            onDeleteRequest: {
                                workspaceToDelete = workspace
                            }
                        )
                        .onHover { hovering in
                            hoveredWorkspace = hovering ? workspace : nil
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
        .adaptiveSoftScrollEdges()
        .sheet(isPresented: $showingCreateWorkspace) {
            WorkspaceFormSheet(
                serverManager: serverManager,
                onSave: { newWorkspace in
                    selectedWorkspace = newWorkspace
                }
            )
            .adaptiveSoftScrollEdges()
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
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $workspaceToManageServers) { workspace in
            LockedWorkspaceServerManagementSheet(
                serverManager: serverManager,
                workspace: workspace
            )
            .adaptiveSoftScrollEdges()
            .frame(width: 560, height: 460)
        }
        .lockedItemAlert(
            .workspace,
            itemName: lockedWorkspaceAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedWorkspaceAlert != nil },
                set: { if !$0 { lockedWorkspaceAlert = nil } }
            )
        )
        .alert("Delete Workspace?", isPresented: Binding(
            get: { workspaceToDelete != nil },
            set: { if !$0 { workspaceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                guard let workspace = workspaceToDelete else { return }
                Task { try? await serverManager.deleteWorkspace(workspace) }
            }
        } message: {
            Text(deleteWarningText(for: workspaceToDelete))
        }
    }

    private func serverCount(for workspace: Workspace) -> Int {
        stateStore.servers.filter { $0.workspaceId == workspace.id }.count
    }

    private func deleteWarningText(for workspace: Workspace?) -> String {
        guard let workspace else {
            return String(localized: "This will delete the workspace and all servers in it. This cannot be undone.")
        }
        let count = serverCount(for: workspace)
        if count == 0 {
            return String(localized: "This will delete the workspace. This cannot be undone.")
        }
        if count == 1 {
            return String(localized: "This will delete the workspace and its 1 server. This cannot be undone.")
        }
        return String(
            format: String(localized: "This will delete the workspace and all %lld servers in it. This cannot be undone."),
            Int64(count)
        )
    }
}

// MARK: - Workspace Switcher Row

struct WorkspaceSwitcherRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isHovered: Bool
    var isLocked: Bool = false
    let serverCount: Int
    let onSelect: () -> Void
    let onEdit: () -> Void
    var onLockedTap: (() -> Void)? = nil
    var onManageServers: (() -> Void)? = nil
    let onDeleteRequest: () -> Void

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    private var selectedTextColor: Color {
        Color(nsColor: .selectedTextColor)
    }
    #endif

    var body: some View {
        HStack(spacing: 12) {
            // Icon or color indicator
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 8)
            } else {
                Circle()
                    .fill(Color.fromHex(workspace.colorHex))
                    .frame(width: 8, height: 8)
            }

            Text(workspace.name)
                .font(.body)
                .fontWeight(.semibold)
                #if os(macOS)
                .foregroundStyle(isLocked ? .secondary : (isSelected ? selectedTextColor : .primary))
                #else
                .foregroundStyle(isLocked ? .secondary : (isSelected ? Color.accentColor : .primary))
                #endif
                .lineLimit(1)

            Spacer(minLength: 8)

            if isLocked {
                LockedBadge()
            } else {
                PillBadge(text: "\(serverCount)", color: .secondary)

                if isHovered || isSelected {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            #if os(macOS)
                            .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                            #else
                            .foregroundStyle(.secondary)
                            #endif
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isLocked,
               serverCount > 0,
               (isHovered || isSelected),
               let onManageServers {
                Button {
                    onManageServers()
                } label: {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #if os(macOS)
        .background(isSelected ? selectionFillColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        #else
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        #endif
        .contentShape(Rectangle())
        .opacity(isLocked ? 0.7 : 1.0)
        .onTapGesture {
            if isLocked {
                onLockedTap?()
            } else {
                onSelect()
            }
        }
        .contextMenu {
            if isLocked {
                Button {
                    onLockedTap?()
                } label: {
                    Label("Unlock with Pro", systemImage: "lock.open.fill")
                }

                if serverCount > 0, let onManageServers {
                    Button {
                        onManageServers()
                    } label: {
                        Label("Manage Servers", systemImage: "server.rack")
                    }
                }
            } else {
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
                    onDeleteRequest()
                } label: {
                    Label("Delete Workspace", systemImage: "trash")
                }
            }
        }
    }
}

struct LockedWorkspaceServerManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let serverManager: ServerManager
    @ObservedObject private var stateStore: ServerStateStore
    let workspace: Workspace

    @State private var serverToMove: Server?

    init(serverManager: ServerManager, workspace: Workspace) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        self.workspace = workspace
    }

    private var workspaceServers: [Server] {
        stateStore.servers
            .filter { $0.workspaceId == workspace.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        #if os(iOS)
        content
        #else
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Manage Locked Workspace") {
                dismiss()
            }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }

    private var content: some View {
        Group {
            if workspaceServers.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No servers left in this workspace.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    Section {
                        ForEach(workspaceServers) { server in
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .fontWeight(.medium)

                                    Text(server.displayAddress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(server.environment.color)
                                        .frame(width: 8, height: 8)
                                    Text(server.environment.displayShortName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button("Move") {
                                    serverToMove = server
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(workspace.name)
                    } footer: {
                        Text("Move servers into an unlocked workspace to keep them accessible on the free plan.")
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
            }
        }
        #if os(iOS)
        .navigationTitle("Manage Locked Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        #endif
        .sheet(item: $serverToMove) { server in
            #if os(iOS)
            NavigationStack {
                MoveServerSheet(
                    serverManager: serverManager,
                    server: server,
                    onMove: { _ in
                        serverToMove = nil
                    }
                )
            }
            .adaptiveSoftScrollEdges()
            #else
            MoveServerSheet(
                serverManager: serverManager,
                server: server,
                onMove: { _ in
                    serverToMove = nil
                }
            )
            #endif
        }
        .adaptiveSoftScrollEdges()
    }
}
