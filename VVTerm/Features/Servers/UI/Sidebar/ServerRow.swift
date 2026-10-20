import SwiftUI

struct ServerRow: View {
    let server: Server
    let teleportAccess: TeleportAccessService?
    let isSelected: Bool
    let isLocked: Bool
    let onSelect: () -> Void
    let onEdit: (Server) -> Void
    var onMove: ((Server) -> Void)? = nil
    let onDuplicate: (Server) -> Void
    let onWake: (Server) -> Void
    let onConnect: (Server) -> Void
    var onLockedTap: (() -> Void)? = nil

    @ObservedObject private var serverManager: ServerManager
    @ObservedObject private var terminalNavigation: TerminalSessionNavigationProjection
    @Environment(\.privacyModeEnabled) private var privacyModeEnabled
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    init(
        serverManager: ServerManager,
        terminalNavigation: TerminalSessionNavigationProjection,
        server: Server,
        teleportAccess: TeleportAccessService?,
        isSelected: Bool,
        isLocked: Bool,
        onSelect: @escaping () -> Void,
        onEdit: @escaping (Server) -> Void,
        onMove: ((Server) -> Void)? = nil,
        onDuplicate: @escaping (Server) -> Void,
        onWake: @escaping (Server) -> Void,
        onConnect: @escaping (Server) -> Void,
        onLockedTap: (() -> Void)? = nil
    ) {
        _serverManager = ObservedObject(wrappedValue: serverManager)
        _terminalNavigation = ObservedObject(wrappedValue: terminalNavigation)
        self.server = server
        self.teleportAccess = teleportAccess
        self.isSelected = isSelected
        self.isLocked = isLocked
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onMove = onMove
        self.onDuplicate = onDuplicate
        self.onWake = onWake
        self.onConnect = onConnect
        self.onLockedTap = onLockedTap
    }

    private var tabCount: Int {
        terminalNavigation.state.tabCountsByServer[server.id, default: 0]
    }

    private var selectedForegroundColor: Color {
        #if os(macOS)
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
        #else
        .accentColor
        #endif
    }

    private var selectionFillColor: Color {
        #if os(macOS)
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
        #else
        return Color.primary.opacity(0.10)
        #endif
    }

    private var sessionIndicatorColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.9) : .secondary
    }

    var body: some View {
        serverLabel
            .background(selectionBackground)
            .opacity(isLocked ? 0.7 : 1.0)
            .contentShape(Rectangle())
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
                    if let onMove {
                        Button { onMove(server) } label: {
                            Label("Move to Workspace", systemImage: "arrow.turn.right.up")
                        }
                    }
                    duplicateButton
                    Button { onEdit(server) } label: {
                        Label("Server Settings", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        Task { try? await serverManager.deleteServer(server) }
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                } else {
                    Button {
                        onConnect(server)
                    } label: {
                        Label("Open Connection", systemImage: "point.forward.to.point.capsulepath.fill")
                    }
                    if let onMove {
                        Button { onMove(server) } label: {
                            Label("Move to Workspace", systemImage: "arrow.turn.right.up")
                        }
                    }
                    duplicateButton
                    ServerWakeActionButton(
                        serverID: server.id,
                        onAction: { onWake(server) }
                    )
                    Button { onEdit(server) } label: {
                        Label("Server Settings", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { try? await serverManager.deleteServer(server) }
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                }
            }
    }

    private var duplicateButton: some View {
        Button { onDuplicate(server) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .accessibilityIdentifier("vvterm.serverList.duplicate.\(server.id.uuidString)")
    }

    private var serverLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            } else {
                ServerIconView(
                    server: server,
                    size: 18,
                    tint: isSelected ? selectedForegroundColor : .secondary
                )
                .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if server.connectionMode == .teleport {
                        Image(systemName: ServerTransportSelection.teleport.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Teleport")
                    }
                    Text(server.visibleHost(privacyModeEnabled: privacyModeEnabled))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Circle()
                        .fill(server.environment.color)
                        .frame(width: 6, height: 6)

                    Text(server.environment.displayShortName)
                        .font(.caption2)
                        .foregroundStyle(server.environment.color)
                        .lineLimit(1)
                }

                if server.connectionMode == .teleport, let configuration = server.teleportConfiguration {
                    TeleportAccessBadge(configuration: configuration, service: teleportAccess)
                        .id(configuration)
                }
            }

            Spacer(minLength: 8)

            if isLocked {
                LockedBadge()
            } else if tabCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(tabCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(sessionIndicatorColor)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(selectionFillColor)
        }
    }
}
