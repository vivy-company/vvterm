import Foundation
import Network
import Combine
import os.log

// MARK: - Network Monitor

nonisolated final class ReachabilityCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func completeOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }
}

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    nonisolated enum Readiness: String, Hashable, Sendable {
        case unknown
        case ready
        case unavailable
    }

    nonisolated enum ConnectionType: String, Hashable, Sendable {
        case wifi = "WiFi"
        case cellular = "Cellular"
        case ethernet = "Ethernet"
        case unknown = "Unknown"

        var displayName: String {
            switch self {
            case .wifi: return String(localized: "WiFi")
            case .cellular: return String(localized: "Cellular")
            case .ethernet: return String(localized: "Ethernet")
            case .unknown: return String(localized: "Unknown")
            }
        }

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .ethernet: return "cable.connector"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    nonisolated struct Snapshot: Hashable, Sendable {
        let readiness: Readiness
        let connectionType: ConnectionType
        let isExpensive: Bool
        let isConstrained: Bool

        static let unknown = Snapshot(
            readiness: .unknown,
            connectionType: .unknown,
            isExpensive: false,
            isConstrained: false
        )
    }

    @Published private(set) var snapshot: Snapshot = .unknown

    var readiness: Readiness { snapshot.readiness }
    var isConnected: Bool { readiness == .ready }
    var isOffline: Bool { readiness == .unavailable }
    var connectionType: ConnectionType { snapshot.connectionType }
    var isExpensive: Bool { snapshot.isExpensive }
    var isConstrained: Bool { snapshot.isConstrained }

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.vivy.vvterm.networkmonitor")
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "Network"
    )

    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let nextSnapshot = Self.snapshot(for: path)
            DispatchQueue.main.async { [weak self] in
                self?.apply(nextSnapshot)
            }
        }
        monitor.start(queue: queue)
    }

    /// Reconciles state from the monitor's latest path after foregrounding.
    /// Background delivery can be suspended even though `currentPath` advanced.
    func refreshCurrentPath() {
        apply(Self.snapshot(for: monitor.currentPath))
    }

    private nonisolated static func snapshot(for path: NWPath) -> Snapshot {
        let connectionType: ConnectionType
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .ethernet
        } else {
            connectionType = .unknown
        }

        return Snapshot(
            readiness: path.status == .satisfied ? .ready : .unavailable,
            connectionType: connectionType,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private func apply(_ nextSnapshot: Snapshot) {
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot

        if nextSnapshot.readiness == .ready {
            logger.info(
                "Network path ready via \(nextSnapshot.connectionType.rawValue, privacy: .public), expensive=\(nextSnapshot.isExpensive, privacy: .public), constrained=\(nextSnapshot.isConstrained, privacy: .public)"
            )
        } else {
            logger.warning("Network path unavailable")
        }
    }

    /// Check if a specific host is reachable
    func checkHostReachability(_ host: String, port: UInt16 = 22) async -> Bool {
        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let connection = NWConnection(to: endpoint, using: .tcp)
            let completionState = ReachabilityCompletionState()

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(5))
                connection.cancel()
            }

            let finish: @Sendable (Bool) -> Void = { isReachable in
                guard completionState.completeOnce() else { return }
                timeoutTask.cancel()
                connection.cancel()
                continuation.resume(returning: isReachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }
    }
}

// MARK: - Network Status Extension

extension NetworkMonitor {
    var statusDescription: String {
        if isOffline {
            return String(localized: "No Connection")
        }
        var description = connectionType.displayName
        if isExpensive {
            description += String(localized: " (Metered)")
        }
        if isConstrained {
            description += String(localized: " (Low Data)")
        }
        return description
    }
}
