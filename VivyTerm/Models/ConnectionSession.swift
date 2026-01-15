import Foundation

// MARK: - Connection State

enum ConnectionState: Hashable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
    case idle  // Deprecated: kept for switch exhaustiveness

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var statusString: String {
        switch self {
        case .disconnected, .idle: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

// MARK: - Connection Session (Tab)

struct ConnectionSession: Identifiable, Hashable {
    let id: UUID
    let serverId: UUID
    var title: String
    var connectionState: ConnectionState
    var createdAt: Date
    var lastActivity: Date
    var terminalSurfaceId: String?
    var autoReconnect: Bool
    var tmuxStatus: TmuxStatus
    /// If set, this session is a split child of the parent session (not shown in tabs)
    var parentSessionId: UUID?

    init(
        id: UUID = UUID(),
        serverId: UUID,
        title: String,
        connectionState: ConnectionState = .disconnected,
        createdAt: Date = Date(),
        lastActivity: Date = Date(),
        terminalSurfaceId: String? = nil,
        autoReconnect: Bool = true,
        tmuxStatus: TmuxStatus = .unknown,
        parentSessionId: UUID? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.title = title
        self.connectionState = connectionState
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.terminalSurfaceId = terminalSurfaceId
        self.autoReconnect = autoReconnect
        self.tmuxStatus = tmuxStatus
        self.parentSessionId = parentSessionId
    }

    /// Whether this is a root tab session (not a split child)
    var isTabRoot: Bool {
        parentSessionId == nil
    }

    var isConnected: Bool {
        connectionState.isConnected
    }

    mutating func updateLastActivity() {
        lastActivity = Date()
    }
}

// MARK: - Connection View Tab

struct ConnectionViewTab: Identifiable, Hashable, Codable, Equatable {
    let id: String
    let localizedKey: String
    let icon: String

    static let stats = ConnectionViewTab(
        id: "stats",
        localizedKey: "Stats",
        icon: "chart.bar.xaxis"
    )

    static let terminal = ConnectionViewTab(
        id: "terminal",
        localizedKey: "Terminal",
        icon: "terminal"
    )

    static let defaultOrder: [ConnectionViewTab] = [.stats, .terminal]
    static let allTabs: [ConnectionViewTab] = defaultOrder

    static func from(id: String) -> ConnectionViewTab? {
        defaultOrder.first { $0.id == id }
    }
}
