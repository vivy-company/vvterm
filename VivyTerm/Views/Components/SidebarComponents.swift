import SwiftUI

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let isSelected: Bool
    let onEdit: (Server) -> Void
    let onSelect: () -> Void
    var onLockedTap: (() -> Void)? = nil

    @ObservedObject private var tabManager = TerminalTabManager.shared
    @ObservedObject private var serverManager = ServerManager.shared

    private var isLocked: Bool {
        serverManager.isServerLocked(server)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator or lock icon
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 8)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .foregroundStyle(isLocked ? .secondary : .primary)

                Text(server.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLocked {
                LockedBadge()
            } else {
                // Environment badge
                Text(server.environment.displayShortName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(server.environment.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(server.environment.color.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(selectionBackground)
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
                Button("Connect") {
                    tabManager.connectedServerIds.insert(server.id)
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
    }

    private var statusColor: Color {
        // Check if server is connected (viewing stats/terminal)
        let isConnected = tabManager.connectedServerIds.contains(server.id)
        // Check if has terminal tabs open
        let hasTerminals = !tabManager.tabs(for: server.id).isEmpty

        if hasTerminals {
            return .green // Active SSH terminals
        } else if isConnected {
            return .orange // Connected (stats) but no terminals
        } else {
            return .secondary.opacity(0.3) // Not connected
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
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
    let placeholder: LocalizedStringKey
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
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
