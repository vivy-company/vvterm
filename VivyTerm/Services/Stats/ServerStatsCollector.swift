import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

@MainActor
final class ServerStatsCollector: ObservableObject {
    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var isCollecting = false

    private var collectTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Stats")

    // Previous values for rate calculation
    private var prevNetRx: UInt64 = 0
    private var prevNetTx: UInt64 = 0
    private var prevTimestamp: Date?
    private var prevCpuValues: (user: UInt64, nice: UInt64, system: UInt64, idle: UInt64, iowait: UInt64, irq: UInt64, softirq: UInt64, steal: UInt64)?

    // MARK: - Collection

    func startCollecting(for session: ConnectionSession) async {
        guard !isCollecting else { return }
        isCollecting = true

        // Reset previous values
        prevNetRx = 0
        prevNetTx = 0
        prevTimestamp = nil
        prevCpuValues = nil

        // Run collection in background to avoid blocking main thread
        collectTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // Check if still collecting AND session exists
                let shouldContinue = await MainActor.run {
                    guard self.isCollecting else { return false }
                    return ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
                }
                guard shouldContinue else { break }

                await self.collectStats(for: session)
                try? await Task.sleep(for: .seconds(2))
            }

            // Cleanup when loop exits
            await MainActor.run { [weak self] in
                self?.isCollecting = false
            }
        }
    }

    func stopCollecting() {
        isCollecting = false
        collectTask?.cancel()
        collectTask = nil
    }

    private func collectStats(for session: ConnectionSession) async {
        // Check if session still exists before collecting
        let (client, sessionExists) = await MainActor.run {
            let exists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
            let client = ConnectionSessionManager.shared.sshClient(for: session)
            return (client, exists)
        }

        // Stop collecting if session no longer exists
        guard sessionExists else {
            await MainActor.run { self.stopCollecting() }
            return
        }

        guard let client = client else { return }

        do {
            // Collect all data in background first
            var newStats = ServerStats()
            let existingStats = await MainActor.run { self.stats }

            // System info (only first time or periodically)
            if existingStats.osInfo.isEmpty {
                let unameOutput = try await client.execute("uname -srm")
                newStats.osInfo = unameOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                let hostnameOutput = try await client.execute("hostname")
                newStats.hostname = hostnameOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                // CPU cores
                let coresOutput = try await client.execute("nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1")
                newStats.cpuCores = Int(coresOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            } else {
                newStats.osInfo = existingStats.osInfo
                newStats.hostname = existingStats.hostname
                newStats.cpuCores = existingStats.cpuCores
            }

            // CPU detailed
            let cpuOutput = try await client.execute("cat /proc/stat | head -1")
            let prevCpu = await MainActor.run { self.prevCpuValues }
            let cpuDetails = parseProcStatDetailedNonisolated(cpuOutput, prevValues: prevCpu)
            newStats.cpuUser = cpuDetails.result.user
            newStats.cpuSystem = cpuDetails.result.system
            newStats.cpuIowait = cpuDetails.result.iowait
            newStats.cpuSteal = cpuDetails.result.steal
            newStats.cpuIdle = cpuDetails.result.idle
            newStats.cpuUsage = cpuDetails.result.total
            let newCpuValues = cpuDetails.newPrevValues

            // Memory detailed
            let memOutput = try await client.execute("cat /proc/meminfo")
            let memDetails = parseProcMeminfoDetailed(memOutput)
            newStats.memoryTotal = memDetails.total
            newStats.memoryUsed = memDetails.used
            newStats.memoryFree = memDetails.free
            newStats.memoryCached = memDetails.cached
            newStats.memoryBuffers = memDetails.buffers

            // All volumes
            let dfOutput = try await client.execute("df -BM -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2")
            newStats.volumes = parseDfVolumes(dfOutput)

            // Network with rate calculation
            let netOutput = try await client.execute("cat /proc/net/dev")
            let (netRx, netTx) = parseProcNetDev(netOutput)
            let now = Date()

            let (prevRx, prevTx, prevTime) = await MainActor.run {
                (self.prevNetRx, self.prevNetTx, self.prevTimestamp)
            }

            if let prevTime = prevTime, prevRx > 0 || prevTx > 0 {
                let elapsed = now.timeIntervalSince(prevTime)
                if elapsed > 0 {
                    newStats.networkRxSpeed = UInt64(Double(netRx - prevRx) / elapsed)
                    newStats.networkTxSpeed = UInt64(Double(netTx - prevTx) / elapsed)
                }
            }

            newStats.networkRxTotal = netRx
            newStats.networkTxTotal = netTx

            // Load average
            let loadOutput = try await client.execute("cat /proc/loadavg")
            newStats.loadAverage = parseLoadAvg(loadOutput)

            // Uptime
            let uptimeOutput = try await client.execute("cat /proc/uptime")
            newStats.uptime = parseUptime(uptimeOutput)

            // Process count
            let procCount = try await client.execute("ls -d /proc/[0-9]* 2>/dev/null | wc -l")
            newStats.processCount = Int(procCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

            // Top processes
            let psOutput = try await client.execute("ps aux --sort=-%cpu | head -6")
            newStats.topProcesses = parsePs(psOutput)

            newStats.timestamp = now

            // Single batch update on main thread
            await MainActor.run {
                self.stats = newStats
                self.prevNetRx = netRx
                self.prevNetTx = netTx
                self.prevTimestamp = now
                self.prevCpuValues = newCpuValues

                // Update history
                self.cpuHistory.append(StatsPoint(timestamp: now, value: newStats.cpuUsage))
                self.memoryHistory.append(StatsPoint(timestamp: now, value: Double(newStats.memoryUsed)))

                // Keep last 60 points
                if self.cpuHistory.count > 60 { self.cpuHistory.removeFirst() }
                if self.memoryHistory.count > 60 { self.memoryHistory.removeFirst() }
            }

        } catch {
            logger.error("Failed to collect stats: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsers

    private typealias CpuValues = (user: UInt64, nice: UInt64, system: UInt64, idle: UInt64, iowait: UInt64, irq: UInt64, softirq: UInt64, steal: UInt64)
    private typealias CpuResult = (total: Double, user: Double, system: Double, iowait: Double, steal: Double, idle: Double)

    /// Nonisolated CPU parser that can be called from background tasks
    private nonisolated func parseProcStatDetailedNonisolated(_ output: String, prevValues: CpuValues?) -> (result: CpuResult, newPrevValues: CpuValues) {
        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard components.count >= 8 else {
            return (result: (0, 0, 0, 0, 0, 0), newPrevValues: (0, 0, 0, 0, 0, 0, 0, 0))
        }

        let user = UInt64(components[1]) ?? 0
        let nice = UInt64(components[2]) ?? 0
        let system = UInt64(components[3]) ?? 0
        let idle = UInt64(components[4]) ?? 0
        let iowait = UInt64(components[5]) ?? 0
        let irq = UInt64(components[6]) ?? 0
        let softirq = UInt64(components[7]) ?? 0
        let steal = components.count > 8 ? (UInt64(components[8]) ?? 0) : 0

        let current: CpuValues = (user: user, nice: nice, system: system, idle: idle, iowait: iowait, irq: irq, softirq: softirq, steal: steal)

        if let prev = prevValues {
            let dUser = Double(current.user - prev.user + current.nice - prev.nice)
            let dSystem = Double(current.system - prev.system + current.irq - prev.irq + current.softirq - prev.softirq)
            let dIdle = Double(current.idle - prev.idle)
            let dIowait = Double(current.iowait - prev.iowait)
            let dSteal = Double(current.steal - prev.steal)

            let total = dUser + dSystem + dIdle + dIowait + dSteal
            if total > 0 {
                return (
                    result: (
                        total: (dUser + dSystem + dIowait + dSteal) / total * 100,
                        user: dUser / total * 100,
                        system: dSystem / total * 100,
                        iowait: dIowait / total * 100,
                        steal: dSteal / total * 100,
                        idle: dIdle / total * 100
                    ),
                    newPrevValues: current
                )
            }
        }

        return (result: (0, 0, 0, 0, 0, 100), newPrevValues: current)
    }

    private nonisolated func parseProcMeminfoDetailed(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64) {
        var total: UInt64 = 0
        var free: UInt64 = 0
        var available: UInt64 = 0
        var buffers: UInt64 = 0
        var cached: UInt64 = 0
        var sReclaimable: UInt64 = 0

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let valueStr = parts[1].components(separatedBy: .whitespaces).first ?? "0"
            let value = UInt64(valueStr) ?? 0

            switch parts[0] {
            case "MemTotal": total = value * 1024
            case "MemFree": free = value * 1024
            case "MemAvailable": available = value * 1024
            case "Buffers": buffers = value * 1024
            case "Cached": cached = value * 1024
            case "SReclaimable": sReclaimable = value * 1024
            default: break
            }
        }

        let actualCached = cached + sReclaimable
        let used = total - available
        return (total, used, free, actualCached, buffers)
    }

    private nonisolated func parseDfVolumes(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 6 else { continue }

            // Parse size in MB (from -BM flag)
            let totalStr = parts[1].replacingOccurrences(of: "M", with: "")
            let usedStr = parts[2].replacingOccurrences(of: "M", with: "")
            let mountPoint = parts[5]

            let total = UInt64(totalStr) ?? 0
            let used = UInt64(usedStr) ?? 0

            // Skip small volumes
            if total < 100 { continue }

            volumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: used * 1024 * 1024,
                total: total * 1024 * 1024
            ))
        }

        return volumes
    }

    private nonisolated func parseProcNetDev(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        for line in output.components(separatedBy: .newlines) {
            guard line.contains(":") && !line.contains("lo:") else { continue }

            let parts = line.components(separatedBy: ":").last?
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty } ?? []

            guard parts.count >= 9 else { continue }

            totalRx += UInt64(parts[0]) ?? 0
            totalTx += UInt64(parts[8]) ?? 0
        }

        return (totalRx, totalTx)
    }

    private nonisolated func parseLoadAvg(_ output: String) -> (Double, Double, Double) {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)

        guard parts.count >= 3 else { return (0, 0, 0) }

        return (
            Double(parts[0]) ?? 0,
            Double(parts[1]) ?? 0,
            Double(parts[2]) ?? 0
        )
    }

    private nonisolated func parseUptime(_ output: String) -> TimeInterval {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)

        guard let uptimeStr = parts.first else { return 0 }
        return TimeInterval(uptimeStr) ?? 0
    }

    private nonisolated func parsePs(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 11 else { continue }

            let pid = Int(parts[1]) ?? 0
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let name = parts[10]

            processes.append(ProcessInfo(pid: pid, name: name, cpuPercent: cpu, memoryPercent: mem))
        }

        return processes
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

    // Memory detailed
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
    let id = UUID()
    let mountPoint: String
    let used: UInt64
    let total: UInt64

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
    let id = UUID()
    let timestamp: Date
    let value: Double
}
