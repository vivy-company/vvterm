import SwiftUI
import Charts

// MARK: - Cross-platform colors

#if os(iOS)
private let cardBackground = Color(UIColor.secondarySystemBackground)
private let screenBackground = Color(UIColor.systemBackground)
#else
// Use a visible card background that contrasts with the window background
private let cardBackground = Color.primary.opacity(0.06)
private let screenBackground = Color(NSColor.windowBackgroundColor)
#endif

// MARK: - Server Stats View

struct ServerStatsView: View {
    let server: Server
    let isVisible: Bool

    @StateObject private var statsCollector = ServerStatsCollector()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Header with server name and OS
                ServerHeaderCard(
                    serverName: server.name,
                    osInfo: statsCollector.stats.osInfo
                )

                // CPU Card
                CPUStatsCard(
                    usage: statsCollector.stats.cpuUsage,
                    user: statsCollector.stats.cpuUser,
                    system: statsCollector.stats.cpuSystem,
                    iowait: statsCollector.stats.cpuIowait,
                    steal: statsCollector.stats.cpuSteal,
                    idle: statsCollector.stats.cpuIdle,
                    cores: statsCollector.stats.cpuCores,
                    uptime: statsCollector.stats.uptime,
                    loadAverage: statsCollector.stats.loadAverage
                )

                // Memory Card
                MemoryStatsCard(
                    used: statsCollector.stats.memoryUsed,
                    free: statsCollector.stats.memoryFree,
                    cached: statsCollector.stats.memoryCached,
                    total: statsCollector.stats.memoryTotal,
                    percent: statsCollector.stats.memoryPercent
                )

                // Network Card
                NetworkStatsCard(
                    txSpeed: statsCollector.stats.networkTxSpeed,
                    rxSpeed: statsCollector.stats.networkRxSpeed,
                    txTotal: statsCollector.stats.networkTxTotal,
                    rxTotal: statsCollector.stats.networkRxTotal
                )

                // Volumes - always show, empty state handled inside
                VolumesCard(volumes: statsCollector.stats.volumes)

                // Top Processes - always show, empty state handled inside
                ProcessesCard(processes: statsCollector.stats.topProcesses)
            }
            .padding()
            .drawingGroup()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(screenBackground)
        .task(id: isVisible) {
            // Start/stop collection based on visibility
            if isVisible {
                await statsCollector.startCollecting(for: server)
            } else {
                statsCollector.stopCollecting()
            }
        }
        .onDisappear {
            statsCollector.stopCollecting()
        }
    }
}

// MARK: - Server Header Card

private struct ServerHeaderCard: View, Equatable {
    let serverName: String
    let osInfo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(serverName)
                .font(.title2)
                .fontWeight(.bold)

            if !osInfo.isEmpty {
                Text(osInfo)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - CPU Stats Card

private struct CPUStatsCard: View, Equatable {
    let usage: Double
    let user: Double
    let system: Double
    let iowait: Double
    let steal: Double
    let idle: Double
    let cores: Int
    let uptime: TimeInterval
    let loadAverage: (Double, Double, Double)

    static func == (lhs: CPUStatsCard, rhs: CPUStatsCard) -> Bool {
        lhs.usage == rhs.usage && lhs.user == rhs.user && lhs.system == rhs.system &&
        lhs.iowait == rhs.iowait && lhs.steal == rhs.steal && lhs.idle == rhs.idle &&
        lhs.cores == rhs.cores && lhs.uptime == rhs.uptime &&
        lhs.loadAverage.0 == rhs.loadAverage.0 && lhs.loadAverage.1 == rhs.loadAverage.1 && lhs.loadAverage.2 == rhs.loadAverage.2
    }

    var body: some View {
        VStack(spacing: 12) {
            // Top row: breakdown + gauge on right
            HStack(spacing: 16) {
                // Breakdown grid
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        StatLabel(color: .pink, label: "SYS", value: "\(Int(system)) %")
                        StatLabel(color: .green, label: "USER", value: "\(Int(user)) %")
                    }
                    HStack(spacing: 16) {
                        StatLabel(color: .yellow, label: "IOWAIT", value: "\(Int(iowait)) %")
                        StatLabel(color: .purple, label: "STEAL", value: "\(Int(steal)) %")
                    }
                }

                Spacer()

                // Circular gauge with percentage inside (on right)
                ZStack {
                    CircularGauge(value: usage / 100, color: cpuColor)
                    Text("\(Int(usage))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 36)
                }
                .frame(width: 50, height: 50)
            }

            Divider()

            // Bottom row: cores, idle, uptime, load
            HStack(spacing: 0) {
                StatColumn(label: "CORES", value: "\(cores)")
                StatColumn(label: "IDLE", value: "\(Int(idle)) %")
                StatColumn(label: "UPTIME", value: formatUptime(uptime))
                StatColumn(label: "LOAD", value: String(format: "%.1f,%.1f,%.1f", loadAverage.0, loadAverage.1, loadAverage.2))
            }
        }
        .padding()
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var cpuColor: Color {
        if usage > 90 { return .red }
        if usage > 70 { return .orange }
        return .green
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        if days > 0 { return "\(days) D" }
        return "\(hours) H"
    }
}

// MARK: - Memory Stats Card

private struct MemoryStatsCard: View, Equatable {
    let used: UInt64
    let free: UInt64
    let cached: UInt64
    let total: UInt64
    let percent: Double

    var body: some View {
        HStack(spacing: 16) {
            // Labels
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    StatLabel(color: .secondary, label: "FREE", value: formatBytes(free))
                    StatLabel(color: .green, label: "USED", value: formatBytes(used))
                }
                HStack(spacing: 16) {
                    StatLabel(color: .blue, label: "CACHED", value: formatBytes(cached))
                    StatLabel(color: .secondary, label: "TOTAL", value: formatBytes(total))
                }
            }

            Spacer()

            // Ring chart with percentage
            ZStack {
                CircularGauge(value: percent / 100, color: memoryColor)
                Text("\(Int(percent))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 36)
            }
            .frame(width: 50, height: 50)
        }
        .padding()
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var memoryColor: Color {
        if percent > 90 { return .red }
        if percent > 70 { return .orange }
        return .green
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f G", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f M", mb)
    }
}

// MARK: - Network Stats Card

private struct NetworkStatsCard: View, Equatable {
    let txSpeed: UInt64
    let rxSpeed: UInt64
    let txTotal: UInt64
    let rxTotal: UInt64

    var body: some View {
        HStack(spacing: 16) {
            // Speed labels
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    StatLabel(color: .green, label: "↑/S", value: formatSpeed(txSpeed))
                    StatLabel(color: .orange, label: "↓/S", value: formatSpeed(rxSpeed))
                }
                HStack(spacing: 16) {
                    StatLabel(color: .green, label: "↑ TOTAL", value: formatBytes(txTotal))
                    StatLabel(color: .orange, label: "↓ TOTAL", value: formatBytes(rxTotal))
                }
            }

            Spacer()

            // Dual ring indicator
            ZStack {
                // RX ring (outer)
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 4)
                    .frame(width: 50, height: 50)
                Circle()
                    .trim(from: 0, to: min(Double(rxSpeed) / 10_000_000, 1)) // 10 MB/s max
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))

                // TX ring (inner)
                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 4)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: min(Double(txSpeed) / 10_000_000, 1))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding()
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatSpeed(_ bytesPerSec: UInt64) -> String {
        let mbps = Double(bytesPerSec) / 1_048_576
        if mbps >= 1 { return String(format: "%.1f M/s", mbps) }
        let kbps = Double(bytesPerSec) / 1024
        if kbps >= 1 { return String(format: "%.0f K/s", kbps) }
        return "0 B/s"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f G", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f M", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f K", kb)
    }
}

// MARK: - Volumes Card

private struct VolumesCard: View {
    let volumes: [VolumeInfo]

    var body: some View {
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Volumes")
                    .font(.headline)
                    .padding(.horizontal)

                ForEach(volumes) { volume in
                    VolumeRow(volume: volume)
                }
            }
            .padding(.vertical)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)

                Text(volume.mountPoint)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Text("\(formatBytes(volume.used))/\(formatBytes(volume.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 4)
                    .fill(volumeColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: min(volume.percent / 100, 1), y: 1, anchor: .leading)
            }
            .frame(height: 8)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
    }

    private var volumeColor: Color {
        if volume.percent > 90 { return .red }
        if volume.percent > 80 { return .orange }
        return .green
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / 1_099_511_627_776
        if tb >= 1 { return String(format: "%.1fT", tb) }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.0fG", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0fM", mb)
    }
}

// MARK: - Processes Card

private struct ProcessesCard: View {
    let processes: [ProcessInfo]

    var body: some View {
        if !processes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Top Processes")
                        .font(.headline)

                    Spacer()

                    HStack(spacing: 24) {
                        Text("CPU")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Text("MEM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                Divider()

                ForEach(processes.prefix(5)) { process in
                    HStack {
                        Text(process.name)
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        Text(String(format: "%.1f%%", process.cpuPercent))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(process.cpuPercent > 50 ? .orange : .secondary)
                            .frame(width: 50, alignment: .trailing)

                        Text(String(format: "%.1f%%", process.memoryPercent))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(process.memoryPercent > 50 ? .orange : .secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding()
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Reusable Components

private struct StatLabel: View, Equatable {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .leading)
        }
    }
}

private struct StatColumn: View, Equatable {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CircularGauge: View, Equatable {
    let value: Double
    let color: Color
    var lineWidth: CGFloat = 6

    static func == (lhs: CircularGauge, rhs: CircularGauge) -> Bool {
        lhs.value == rhs.value && lhs.lineWidth == rhs.lineWidth
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: min(value, 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: value)
        }
    }
}
