import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

/// Main stats collector that creates its own SSH connection to collect server stats
@MainActor
final class ServerStatsCollector: ObservableObject {
    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var isCollecting = false
    @Published var connectionError: String?

    private var collectTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "Stats")

    // Own SSH client for stats collection
    private var sshClient: SSHClient?

    // Platform detection and collector
    private var remotePlatform: RemotePlatform = .unknown
    private var platformCollector: PlatformStatsCollector?
    private let context = StatsCollectionContext()

    // MARK: - Collection Control

    func startCollecting(for server: Server) async {
        guard !isCollecting else { return }
        isCollecting = true
        connectionError = nil

        // Reset state
        context.reset()
        remotePlatform = .unknown
        platformCollector = nil

        // Create SSH client and connect
        let client = SSHClient()
        self.sshClient = client

        // Get credentials
        let credentials: ServerCredentials
        do {
            credentials = try KeychainManager.shared.getCredentials(for: server)
        } catch {
            connectionError = "No credentials found"
            isCollecting = false
            return
        }

        // Connect in background
        collectTask = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            do {
                // Connect to server
                _ = try await client.connect(to: server, credentials: credentials)

                await MainActor.run {
                    self.connectionError = nil
                }

                // Start collection loop
                while !Task.isCancelled {
                    let shouldContinue = await MainActor.run { self.isCollecting }
                    guard shouldContinue else { break }

                    await self.collectStats(client: client)
                    try? await Task.sleep(for: .seconds(2))
                }
            } catch {
                await MainActor.run {
                    self.connectionError = error.localizedDescription
                    self.isCollecting = false
                }
            }

            // Cleanup
            await client.disconnect()
            await MainActor.run { [weak self] in
                self?.isCollecting = false
                self?.sshClient = nil
            }
        }
    }

    func stopCollecting() {
        isCollecting = false
        collectTask?.cancel()
        collectTask = nil

        // Disconnect SSH
        if let client = sshClient {
            Task.detached {
                await client.disconnect()
            }
        }
        sshClient = nil
    }

    // MARK: - Stats Collection

    private func collectStats(client: SSHClient) async {
        do {
            // Detect platform and create collector on first run
            if remotePlatform == .unknown {
                let osType = try await client.execute("uname -s 2>/dev/null || ver 2>/dev/null || echo unknown")
                remotePlatform = RemotePlatform.detect(from: osType)
                platformCollector = remotePlatform.createCollector()

                logger.info("Detected remote platform: \(self.remotePlatform.rawValue)")

                // Get initial system info
                let systemInfo = try await platformCollector?.getSystemInfo(client: client)
                await MainActor.run {
                    self.stats.hostname = systemInfo?.hostname ?? ""
                    self.stats.osInfo = systemInfo?.osInfo ?? ""
                    self.stats.cpuCores = systemInfo?.cpuCores ?? 1
                }
            }

            // Collect stats using platform-specific collector
            guard let collector = platformCollector else { return }

            var newStats = try await collector.collectStats(client: client, context: context)

            // Preserve system info
            let existingStats = await MainActor.run { self.stats }
            newStats.hostname = existingStats.hostname
            newStats.osInfo = existingStats.osInfo
            newStats.cpuCores = existingStats.cpuCores

            // Update on main thread
            await MainActor.run {
                self.stats = newStats

                // Update history
                self.cpuHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.cpuUsage))
                self.memoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.memoryUsed)))

                // Keep last 60 points
                if self.cpuHistory.count > 60 { self.cpuHistory.removeFirst() }
                if self.memoryHistory.count > 60 { self.memoryHistory.removeFirst() }
            }

        } catch {
            logger.error("Failed to collect stats: \(error.localizedDescription)")
        }
    }
}

// MARK: - Stats Models

struct ServerStats {
    // System
    var hostname: String = ""
    var osInfo: String = ""
    var cpuCores: Int = 0

    // CPU detailed
    var cpuUsage: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuIowait: Double = 0
    var cpuSteal: Double = 0
    var cpuIdle: Double = 0

    // Memory detailed (in bytes)
    var memoryTotal: UInt64 = 0
    var memoryUsed: UInt64 = 0
    var memoryFree: UInt64 = 0
    var memoryCached: UInt64 = 0
    var memoryBuffers: UInt64 = 0

    // Network (speed in bytes/sec, total in bytes)
    var networkRxSpeed: UInt64 = 0
    var networkTxSpeed: UInt64 = 0
    var networkRxTotal: UInt64 = 0
    var networkTxTotal: UInt64 = 0

    // Volumes
    var volumes: [VolumeInfo] = []

    // System
    var loadAverage: (Double, Double, Double) = (0, 0, 0)
    var uptime: TimeInterval = 0
    var processCount: Int = 0
    var topProcesses: [ProcessInfo] = []
    var timestamp: Date = Date()

    // Computed
    var memoryPercent: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal) * 100
    }
}

struct VolumeInfo: Identifiable {
    let mountPoint: String
    let used: UInt64
    let total: UInt64

    var id: String { mountPoint }

    var percent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }
}

struct ProcessInfo: Identifiable {
    var id: Int { pid }
    let pid: Int
    let name: String
    let cpuPercent: Double
    let memoryPercent: Double
}

struct StatsPoint: Identifiable {
    let timestamp: Date
    let value: Double

    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}
