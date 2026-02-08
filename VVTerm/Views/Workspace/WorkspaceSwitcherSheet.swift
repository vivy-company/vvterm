import SwiftUI

// MARK: - Workspace Switcher Sheet

struct WorkspaceSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverManager: ServerManager
    @Binding var selectedWorkspace: Workspace?

    @State private var hoveredWorkspace: Workspace?
    @State private var showingCreateWorkspace = false
    @State private var workspaceToEdit: Workspace?
    @State private var workspaceToDelete: Workspace?
    @State private var lockedWorkspaceAlert: Workspace?

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
                VStack(spacing: 2) {
                    ForEach(serverManager.workspaces) { workspace in
                        WorkspaceSwitcherRow(
                            workspace: workspace,
                            isSelected: selectedWorkspace?.id == workspace.id,
                            isHovered: hoveredWorkspace?.id == workspace.id,
                            isLocked: serverManager.isWorkspaceLocked(workspace),
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
        serverManager.servers.filter { $0.workspaceId == workspace.id }.count
    }

    private func deleteWarningText(for workspace: Workspace?) -> String {
        guard let workspace else {
            return "This will delete the workspace and all servers in it. This cannot be undone."
        }
        let count = serverCount(for: workspace)
        if count == 0 {
            return "This will delete the workspace. This cannot be undone."
        }
        if count == 1 {
            return "This will delete the workspace and its 1 server. This cannot be undone."
        }
        return "This will delete the workspace and all \(count) servers in it. This cannot be undone."
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
