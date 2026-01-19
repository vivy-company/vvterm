import Foundation

// MARK: - Platform Stats Protocol

/// Protocol defining the interface for platform-specific stats collection
protocol PlatformStatsCollector: Sendable {
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
}

// MARK: - Stats Collection Context

/// Shared context for stats collection (previous values for rate calculations)
final class StatsCollectionContext: @unchecked Sendable {
    var prevNetRx: UInt64 = 0
    var prevNetTx: UInt64 = 0
    var prevTimestamp: Date?
    var prevCpuValues: LinuxCpuValues?

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
}

// MARK: - Linux CPU Values (used by Linux-like systems)

struct LinuxCpuValues: Sendable {
    let user: UInt64
    let nice: UInt64
    let system: UInt64
    let idle: UInt64
    let iowait: UInt64
    let irq: UInt64
    let softirq: UInt64
    let steal: UInt64
}

// MARK: - Remote Platform Detection

enum RemotePlatform: String, Sendable {
    case linux = "linux"
    case darwin = "darwin"
    case freebsd = "freebsd"
    case openbsd = "openbsd"
    case netbsd = "netbsd"
    case windows = "windows"
    case unknown = "unknown"

    /// Detect platform from uname -s output
    static func detect(from unameOutput: String) -> RemotePlatform {
        let os = unameOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if os.contains("darwin") {
            return .darwin
        } else if os.contains("freebsd") {
            return .freebsd
        } else if os.contains("openbsd") {
            return .openbsd
        } else if os.contains("netbsd") {
            return .netbsd
        } else if os.contains("linux") {
            return .linux
        } else if os.contains("mingw") || os.contains("msys") || os.contains("cygwin") || os.contains("windows") {
            return .windows
        }

        // Default to linux for unknown Unix-like systems
        return .linux
    }

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

enum StatsParsingUtils {
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

        let rxSpeed = UInt64(Double(currentRx - prevRx) / elapsed)
        let txSpeed = UInt64(Double(currentTx - prevTx) / elapsed)

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
