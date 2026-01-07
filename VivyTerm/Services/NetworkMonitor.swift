import Foundation
import Network
import Combine
import os.log

// MARK: - Network Monitor

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: ConnectionType = .unknown
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConstrained: Bool = false

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.vivy.vivyterm.networkmonitor")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Network")

    enum ConnectionType: String {
        case wifi = "WiFi"
        case cellular = "Cellular"
        case ethernet = "Ethernet"
        case unknown = "Unknown"

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .ethernet: return "cable.connector"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained

                // Determine connection type
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .ethernet
                } else {
                    self.connectionType = .unknown
                }

                // Log changes
                if wasConnected != self.isConnected {
                    if self.isConnected {
                        self.logger.info("Network connected via \(self.connectionType.rawValue)")
                    } else {
                        self.logger.warning("Network disconnected")
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// Check if a specific host is reachable
    func checkHostReachability(_ host: String, port: UInt16 = 22) async -> Bool {
        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let connection = NWConnection(to: endpoint, using: .tcp)

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(5))
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    timeoutTask.cancel()
                    continuation.resume(returning: false)
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
        if !isConnected {
            return "No Connection"
        }
        var description = connectionType.rawValue
        if isExpensive {
            description += " (Metered)"
        }
        if isConstrained {
            description += " (Low Data)"
        }
        return description
    }
}
