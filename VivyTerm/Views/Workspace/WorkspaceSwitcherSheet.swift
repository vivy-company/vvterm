import SwiftUI

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
