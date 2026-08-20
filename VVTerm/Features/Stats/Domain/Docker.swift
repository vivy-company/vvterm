import Foundation

nonisolated struct DockerStats: Equatable, Sendable {
    var availability: DockerAvailability = .unknown
    var containers: [DockerContainer] = []
    var timestamp: Date = Date()

    var isAvailable: Bool {
        if case .available = availability {
            return true
        }
        return false
    }

    var totalCount: Int {
        containers.count
    }

    var runningCount: Int {
        containers.filter(\.isRunning).count
    }

    var stoppedCount: Int {
        containers.filter { !$0.isRunning }.count
    }

    var unhealthyCount: Int {
        containers.filter { $0.health == .unhealthy }.count
    }

    var restartingCount: Int {
        containers.filter { $0.state == .restarting }.count
    }

    var aggregateCPUPercent: Double {
        containers.reduce(0) { $0 + $1.cpuPercent }
    }

    var memoryUsed: UInt64 {
        containers.reduce(0) { $0 + ($1.memoryUsed ?? 0) }
    }

    var memoryLimit: UInt64 {
        containers.reduce(0) { $0 + ($1.memoryLimit ?? 0) }
    }

    var memoryPercent: Double {
        guard memoryLimit > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryLimit) * 100
    }

    var networkRx: UInt64 {
        containers.reduce(0) { $0 + ($1.networkRx ?? 0) }
    }

    var networkTx: UInt64 {
        containers.reduce(0) { $0 + ($1.networkTx ?? 0) }
    }

    var topContainers: [DockerContainer] {
        containers.sorted { lhs, rhs in
            if lhs.cpuPercent == rhs.cpuPercent {
                return (lhs.memoryUsed ?? 0) > (rhs.memoryUsed ?? 0)
            }
            return lhs.cpuPercent > rhs.cpuPercent
        }
    }
}

nonisolated enum DockerAvailability: Equatable, Sendable {
    case unknown
    case available
    case commandMissing
    case daemonUnavailable(String)
    case permissionDenied(String)
    case unavailable(String)
}

nonisolated struct DockerContainer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let command: String
    let state: DockerContainerState
    let status: String
    let health: DockerHealthStatus
    let createdAt: String
    let runningFor: String
    let ports: String
    let cpuPercent: Double
    let memoryPercent: Double
    let memoryUsed: UInt64?
    let memoryLimit: UInt64?
    let networkRx: UInt64?
    let networkTx: UInt64?
    let blockRead: UInt64?
    let blockWrite: UInt64?
    let pids: Int?

    var shortID: String {
        String(id.prefix(12))
    }

    var displayName: String {
        name.isEmpty ? shortID : name
    }

    var isRunning: Bool {
        state == .running
    }
}

nonisolated enum DockerContainerState: String, Equatable, Sendable {
    case running
    case exited
    case paused
    case restarting
    case created
    case dead
    case removing
    case unknown

    init(rawState: String) {
        self = DockerContainerState(rawValue: rawState.lowercased()) ?? .unknown
    }
}

nonisolated enum DockerHealthStatus: String, Equatable, Sendable {
    case healthy
    case unhealthy
    case starting
    case none

    init(statusText: String) {
        let lowercased = statusText.lowercased()
        if lowercased.contains("unhealthy") {
            self = .unhealthy
        } else if lowercased.contains("healthy") {
            self = .healthy
        } else if lowercased.contains("health: starting") || lowercased.contains("(starting)") {
            self = .starting
        } else {
            self = .none
        }
    }
}

nonisolated enum DockerContainerAction: String, Equatable, Sendable {
    case start
    case stop
    case restart
}
