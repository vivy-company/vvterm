import SwiftUI

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
