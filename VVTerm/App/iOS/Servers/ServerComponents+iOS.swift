//
//  ServerComponents+iOS.swift
//  VVTerm
//

import SwiftUI

#if os(iOS)
// MARK: - Server List Row

struct ServerListRow: View {
    @ObservedObject var serverManager: ServerManager
    let server: Server
    let onTap: () -> Void
    let onEdit: () -> Void
    var onMove: (() -> Void)? = nil
    var onLockedTap: (() -> Void)? = nil

    @EnvironmentObject private var storeManager: StoreManager
    @Environment(\.privacyModeEnabled) private var privacyModeEnabled

    private var isLocked: Bool {
        serverManager.isServerLocked(server, hasProAccess: storeManager.allowsProFeatures)
    }

    var body: some View {
        Button(action: {
            if isLocked {
                onLockedTap?()
            } else {
                onTap()
            }
        }) {
            HStack(spacing: 12) {
                // Server icon or lock icon
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                } else {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }

                // Server info
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(isLocked ? .secondary : .primary)

                    Text(server.visibleAddress(privacyModeEnabled: privacyModeEnabled))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLocked {
                    LockedBadge()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .opacity(isLocked ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onMove {
                Button {
                    onMove()
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(.blue)
            }

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { try? await serverManager.deleteServer(server) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            if isLocked {
                Button {
                    onLockedTap?()
                } label: {
                    Label("Unlock with Pro", systemImage: "lock.open.fill")
                }

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                if let onMove {
                    Button {
                        onMove()
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                }

                Button(role: .destructive) {
                    Task { try? await serverManager.deleteServer(server) }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else {
                Button {
                    onTap()
                } label: {
                    Label("Connect", systemImage: "play.fill")
                }

                if let onMove {
                    Button {
                        onMove()
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                }

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }
}

// MARK: - Active Connection List Row

struct ActiveConnectionListRow: View {
    let title: String
    let status: ActiveConnectionPresentationStatus
    let tmuxStatus: TmuxStatus
    let tabCount: Int
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
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !tmuxStatus.shortLabel.isEmpty {
                    Text(tmuxStatus.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Text(tabCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDisconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark")
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .resumable: return .blue
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var tabCountText: String {
        let count = tabCount
        return count == 1
            ? String(format: String(localized: "%lld tab"), count)
            : String(format: String(localized: "%lld tabs"), count)
    }
}

// MARK: - Workspace Picker Sheet

struct WorkspacePickerSheet: View {
    @ObservedObject var serverManager: ServerManager
    @Binding var selectedWorkspace: Workspace?
    let onDismiss: () -> Void
    @EnvironmentObject private var storeManager: StoreManager

    @State private var lockedWorkspaceAlert: Workspace?
    @State private var showingCreateWorkspace = false
    @State private var workspaceToEdit: Workspace?
    @State private var workspaceToDelete: Workspace?
    @State private var workspaceToManageServers: Workspace?

    var body: some View {
        List {
            ForEach(serverManager.workspaces) { workspace in
                let isLocked = serverManager.isWorkspaceLocked(
                    workspace,
                    hasProAccess: storeManager.allowsProFeatures
                )

                Button {
                    if isLocked {
                        lockedWorkspaceAlert = workspace
                    } else {
                        selectedWorkspace = workspace
                        onDismiss()
                    }
                } label: {
                    HStack {
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        } else {
                            Circle()
                                .fill(Color.fromHex(workspace.colorHex))
                                .frame(width: 12, height: 12)
                        }

                        Text(workspace.name)
                            .foregroundStyle(isLocked ? .secondary : .primary)

                        Spacer()

                        if isLocked {
                            LockedBadge()
                        } else {
                            if selectedWorkspace?.id == workspace.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }

                            Text(serverManager.servers(in: workspace, environment: nil).count, format: .number)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .opacity(isLocked ? 0.7 : 1.0)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if isLocked {
                        if serverManager.servers(in: workspace, environment: nil).count > 0 {
                            Button {
                                workspaceToManageServers = workspace
                            } label: {
                                Label("Manage Servers", systemImage: "server.rack")
                            }
                            .tint(.blue)
                        }

                        Button {
                            lockedWorkspaceAlert = workspace
                        } label: {
                            Label("Unlock with Pro", systemImage: "lock.open.fill")
                        }
                        .tint(.orange)
                    } else {
                        Button {
                            workspaceToEdit = workspace
                        } label: {
                            Label("Edit Workspace", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isLocked {
                        Button(role: .destructive) {
                            workspaceToDelete = workspace
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    if isLocked {
                        if serverManager.servers(in: workspace, environment: nil).count > 0 {
                            Button {
                                workspaceToManageServers = workspace
                            } label: {
                                Label("Manage Servers", systemImage: "server.rack")
                            }
                        }

                        Button {
                            lockedWorkspaceAlert = workspace
                        } label: {
                            Label("Unlock with Pro", systemImage: "lock.open.fill")
                        }
                    } else {
                        Button {
                            workspaceToEdit = workspace
                        } label: {
                            Label("Edit Workspace", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            workspaceToDelete = workspace
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
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
            NavigationStack {
                LockedWorkspaceServerManagementSheet(
                    serverManager: serverManager,
                    workspace: workspace
                )
            }
            .adaptiveSoftScrollEdges()
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
                if let workspace = workspaceToDelete {
                    deleteWorkspace(workspace)
                }
            }
        } message: {
            Text(deleteWarningText(for: workspaceToDelete))
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        Task {
            try? await serverManager.deleteWorkspace(workspace)
            if selectedWorkspace?.id == workspace.id {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
    }

    private func deleteWarningText(for workspace: Workspace?) -> String {
        guard let workspace else {
            return String(localized: "This will delete the workspace and all servers in it. This cannot be undone.")
        }
        let count = serverManager.servers(in: workspace, environment: nil).count
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
#endif
