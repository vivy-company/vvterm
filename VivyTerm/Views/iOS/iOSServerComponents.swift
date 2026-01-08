//
//  iOSServerComponents.swift
//  VivyTerm
//

import SwiftUI

#if os(iOS)
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

                    Text(session.connectionState.statusString)
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
        case .idle: return .gray
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
                            .fill(Color.fromHex(workspace.colorHex))
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
#endif
