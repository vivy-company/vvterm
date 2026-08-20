import Foundation

// MARK: - Platform Stats Protocol

/// Protocol defining the interface for platform-specific stats collection
nonisolated protocol PlatformStatsCollector: Sendable {
    /// Collect stats from the remote server
    /// - Parameters:
    ///   - client: SSH client to execute commands
    ///   - context: Shared context for rate calculations
    /// - Returns: Collected server stats
    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats

    /// Get initial system info (hostname, OS, CPU cores)
    /// - Parameter client: SSH client to execute commands
    /// - Returns: System info tuple
    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int)

    /// Get stable hardware details used by the system info sheet.
    /// Platforms may return partial data; collectors should avoid throwing for missing optional probes.
    func collectProfile(client: SSHClient) async throws -> HardwareProfile

    /// Collect a fuller process list for detail sheets.
    /// Periodic collectors may keep their process list capped for SSH/UI performance.
    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo]

    /// Loads health for one already-resolved physical device on demand.
    /// Missing tools and unsupported devices are returned as capability states;
    /// only transport failures and cancellation are thrown.
    func collectStorageHealth(
        client: SSHClient,
        target: StorageHealthProbeTarget
    ) async throws -> StorageDeviceHealthResult
}

nonisolated struct VolumeCollectionMetadata: Equatable, Sendable {
    let stableIdentifier: String?
    let fileSystem: String
}

nonisolated func parseBSDMountVolumeMetadata(_ output: String) -> [String: VolumeCollectionMetadata] {
    var metadata: [String: VolumeCollectionMetadata] = [:]
    for line in output.components(separatedBy: .newlines) {
        guard let onRange = line.range(of: " on ") else { continue }

        let source = line[..<onRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mountedDescription = line[onRange.upperBound...]
        let fileSystem: String
        if let typeRange = mountedDescription.range(of: " type ") {
            fileSystem = mountedDescription[typeRange.upperBound...]
                .prefix { !$0.isWhitespace && $0 != "(" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let optionsStart = mountedDescription.range(of: " (") {
            fileSystem = mountedDescription[optionsStart.upperBound...]
                .prefix { $0 != "," && $0 != ")" && !$0.isWhitespace }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            continue
        }
        guard !source.isEmpty, !fileSystem.isEmpty else { continue }
        metadata[source] = VolumeCollectionMetadata(
            stableIdentifier: nil,
            fileSystem: fileSystem
        )
    }
    return metadata
}

extension PlatformStatsCollector {
    func collectProfile(client: SSHClient) async throws -> HardwareProfile {
        let systemInfo = try await getSystemInfo(client: client)
        return HardwareProfile(
            hostname: systemInfo.hostname,
            osInfo: systemInfo.osInfo,
            architecture: "",
            kernelVersion: "",
            cpuModel: "",
            cpuVendor: "",
            cpuCores: systemInfo.cpuCores,
            cpuThreads: systemInfo.cpuCores,
            memoryTotal: 0,
            gpus: [],
            collectedAt: Date()
        )
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        []
    }

    func collectStorageHealth(
        client: SSHClient,
        target: StorageHealthProbeTarget
    ) async throws -> StorageDeviceHealthResult {
        try await StorageHealthProbe.collect(client: client, target: target)
    }
}

// MARK: - Stats Collection Context

/// Shared context for stats collection (previous values for rate calculations)
nonisolated final class StatsCollectionContext: @unchecked Sendable {
    var prevNetRx: UInt64 = 0
    var prevNetTx: UInt64 = 0
    var prevTimestamp: Date?
    var prevCpuValues: LinuxCpuValues?
    var prevCpuCoreValues: [String: LinuxCpuValues] = [:]
    private var previousProcessCPUTimeByPID: [Int: TimeInterval] = [:]
    private var previousProcessTimestamp: Date?
    private var lastPeriodicProcessesTimestamp: Date?
    private var lastPeriodicProcesses: [ProcessInfo] = []
    var lastGPUCollectionTimestamp: Date?
    var lastGPUSamples: [GPUSample] = []
    var lastDockerCollectionTimestamp: Date?
    var lastDockerStats = DockerStats()
    private var lastVolumeMetadataRefreshByPlatform: [VolumeIdentity.Platform: Date] = [:]
    private var volumeMetadataByPlatform: [VolumeIdentity.Platform: [String: VolumeCollectionMetadata]] = [:]

    private let lock = NSLock()

    func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    func reset() {
        withLock {
            prevNetRx = 0
            prevNetTx = 0
            prevTimestamp = nil
            prevCpuValues = nil
            prevCpuCoreValues = [:]
            previousProcessCPUTimeByPID = [:]
            previousProcessTimestamp = nil
            lastPeriodicProcessesTimestamp = nil
            lastPeriodicProcesses = []
            lastGPUCollectionTimestamp = nil
            lastGPUSamples = []
            lastDockerCollectionTimestamp = nil
            lastDockerStats = DockerStats()
            lastVolumeMetadataRefreshByPlatform = [:]
            volumeMetadataByPlatform = [:]
        }
    }

    func updateNetwork(rx: UInt64, tx: UInt64, timestamp: Date) {
        withLock {
            prevNetRx = rx
            prevNetTx = tx
            prevTimestamp = timestamp
        }
    }

    func getNetworkPrev() -> (rx: UInt64, tx: UInt64, timestamp: Date?) {
        withLock {
            (prevNetRx, prevNetTx, prevTimestamp)
        }
    }

    func updateCpuValues(_ values: LinuxCpuValues) {
        withLock {
            prevCpuValues = values
        }
    }

    func getCpuValues() -> LinuxCpuValues? {
        withLock {
            prevCpuValues
        }
    }

    func updateCpuCoreValues(_ values: [String: LinuxCpuValues]) {
        withLock {
            prevCpuCoreValues = values
        }
    }

    func getCpuCoreValues() -> [String: LinuxCpuValues] {
        withLock {
            prevCpuCoreValues
        }
    }

    /// Converts cumulative per-process CPU time into a share of total machine capacity.
    /// The first snapshot seeds the interval and intentionally returns no percentages.
    func processCPUPercentages(
        cumulativeCPUTimeByPID: [Int: TimeInterval],
        timestamp: Date,
        logicalProcessorCount: Int
    ) -> [Int: Double] {
        withLock {
            defer {
                previousProcessCPUTimeByPID = cumulativeCPUTimeByPID
                previousProcessTimestamp = timestamp
            }

            guard let previousProcessTimestamp else { return [:] }
            let elapsed = timestamp.timeIntervalSince(previousProcessTimestamp)
            guard elapsed >= 0.25 else { return [:] }

            let capacity = elapsed * Double(max(logicalProcessorCount, 1))
            guard capacity > 0 else { return [:] }

            var percentages: [Int: Double] = [:]
            for (pid, currentCPUTime) in cumulativeCPUTimeByPID {
                guard let previousCPUTime = previousProcessCPUTimeByPID[pid],
                      currentCPUTime >= previousCPUTime else {
                    continue
                }
                let percent = (currentCPUTime - previousCPUTime) / capacity * 100
                if percent.isFinite {
                    percentages[pid] = min(max(percent, 0), 100)
                }
            }
            return percentages
        }
    }

    func shouldCollectPeriodicProcesses(now: Date = Date(), minimumInterval: TimeInterval) -> Bool {
        withLock {
            guard let lastPeriodicProcessesTimestamp else { return true }
            return now.timeIntervalSince(lastPeriodicProcessesTimestamp) >= minimumInterval
        }
    }

    func updatePeriodicProcesses(_ processes: [ProcessInfo], timestamp: Date = Date()) {
        withLock {
            lastPeriodicProcessesTimestamp = timestamp
            if !processes.isEmpty {
                lastPeriodicProcesses = processes
            }
        }
    }

    func getPeriodicProcesses() -> [ProcessInfo] {
        withLock { lastPeriodicProcesses }
    }

    func shouldCollectGPU(now: Date = Date(), minimumInterval: TimeInterval = 5) -> Bool {
        withLock {
            guard let lastGPUCollectionTimestamp else { return true }
            return now.timeIntervalSince(lastGPUCollectionTimestamp) >= minimumInterval
        }
    }

    func markGPUCollected(at timestamp: Date = Date()) {
        withLock {
            lastGPUCollectionTimestamp = timestamp
        }
    }

    func updateGPUSamples(_ samples: [GPUSample], timestamp: Date = Date()) {
        withLock {
            lastGPUCollectionTimestamp = timestamp
            lastGPUSamples = samples
        }
    }

    func getGPUSamples() -> [GPUSample] {
        withLock {
            lastGPUSamples
        }
    }

    func shouldCollectDocker(now: Date = Date(), minimumInterval: TimeInterval = 10) -> Bool {
        withLock {
            guard let lastDockerCollectionTimestamp else { return true }
            return now.timeIntervalSince(lastDockerCollectionTimestamp) >= minimumInterval
        }
    }

    func updateDockerStats(_ stats: DockerStats, timestamp: Date = Date()) {
        withLock {
            lastDockerCollectionTimestamp = timestamp
            lastDockerStats = stats
        }
    }

    func getDockerStats() -> DockerStats {
        withLock {
            lastDockerStats
        }
    }

    /// Claims a metadata refresh window before the caller suspends for SSH work.
    /// This keeps the shared unchecked-Sendable context from launching duplicate
    /// platform inventory probes if collection entry points overlap.
    func beginVolumeMetadataRefresh(
        for platform: VolumeIdentity.Platform,
        now: Date = Date(),
        minimumInterval: TimeInterval = 60
    ) -> Bool {
        withLock {
            if let lastRefresh = lastVolumeMetadataRefreshByPlatform[platform],
               now.timeIntervalSince(lastRefresh) < minimumInterval {
                return false
            }
            lastVolumeMetadataRefreshByPlatform[platform] = now
            return true
        }
    }

    func updateVolumeMetadata(
        _ metadata: [String: VolumeCollectionMetadata],
        for platform: VolumeIdentity.Platform
    ) {
        withLock {
            volumeMetadataByPlatform[platform] = metadata
        }
    }

    func volumeMetadata(for platform: VolumeIdentity.Platform) -> [String: VolumeCollectionMetadata] {
        withLock {
            volumeMetadataByPlatform[platform] ?? [:]
        }
    }
}

// MARK: - Linux CPU Values (used by Linux-like systems)

nonisolated struct LinuxCpuValues: Sendable {
    let user: UInt64
    let nice: UInt64
    let system: UInt64
    let idle: UInt64
    let iowait: UInt64
    let irq: UInt64
    let softirq: UInt64
    let steal: UInt64
}

// MARK: - Platform Collector Factory

extension RemotePlatform {
    /// Get the appropriate stats collector for this platform
    func createCollector() -> PlatformStatsCollector {
        switch self {
        case .linux:
            return LinuxStatsCollector()
        case .darwin:
            return DarwinStatsCollector()
        case .freebsd:
            return FreeBSDStatsCollector()
        case .openbsd:
            return OpenBSDStatsCollector()
        case .netbsd:
            return NetBSDStatsCollector()
        case .windows:
            return WindowsStatsCollector()
        case .unknown:
            return LinuxStatsCollector()
        }
    }
}

// MARK: - Shared Parsing Utilities

nonisolated enum StatsParsingUtils {
    /// Calculate network speed from previous and current values
    static func calculateNetworkSpeed(
        currentRx: UInt64,
        currentTx: UInt64,
        prevRx: UInt64,
        prevTx: UInt64,
        prevTimestamp: Date?,
        now: Date
    ) -> (rxSpeed: UInt64, txSpeed: UInt64) {
        guard let prevTime = prevTimestamp, prevRx > 0 || prevTx > 0 else {
            return (0, 0)
        }

        let elapsed = now.timeIntervalSince(prevTime)
        guard elapsed > 0 else { return (0, 0) }

        let (rxDelta, rxUnderflow) = currentRx.subtractingReportingOverflow(prevRx)
        let (txDelta, txUnderflow) = currentTx.subtractingReportingOverflow(prevTx)

        // Network counters can reset (interface restart, host reboot).
        // Treat underflow as no reliable delta for this interval.
        let safeRxDelta = rxUnderflow ? 0 : rxDelta
        let safeTxDelta = txUnderflow ? 0 : txDelta

        let rxSpeed = UInt64(Double(safeRxDelta) / elapsed)
        let txSpeed = UInt64(Double(safeTxDelta) / elapsed)

        return (rxSpeed, txSpeed)
    }

    /// Parse load average from space-separated string (e.g., "1.23 4.56 7.89")
    static func parseLoadAverage(_ output: String) -> (Double, Double, Double) {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespaces)

        let parts = cleaned.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 3 else { return (0, 0, 0) }

        return (
            Double(parts[0]) ?? 0,
            Double(parts[1]) ?? 0,
            Double(parts[2]) ?? 0
        )
    }

    /// Parse uptime from boot time (Unix timestamp)
    static func uptimeFromBootTime(_ bootTimeSeconds: TimeInterval) -> TimeInterval {
        Date().timeIntervalSince1970 - bootTimeSeconds
    }

    /// Format bytes to human readable string
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
