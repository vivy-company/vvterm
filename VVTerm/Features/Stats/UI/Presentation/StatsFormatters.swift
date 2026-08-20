import Foundation

func formatPercent(_ value: Double) -> String {
    String(format: "%.0f%%", value)
}

func formatSpeed(_ bytesPerSecond: UInt64) -> String {
    let mbps = Double(bytesPerSecond) / 1_048_576
    if mbps >= 1 {
        return String(format: "%.1f MB/s", mbps)
    }

    let kbps = Double(bytesPerSecond) / 1_024
    if kbps >= 1 {
        return String(format: "%.0f KB/s", kbps)
    }

    return "0 B/s"
}

func formatUptimeDetail(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(Int(seconds), 0)
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = (totalSeconds % 3_600) / 60

    if days > 0 {
        return String(format: String(localized: "%lldd %lldh"), Int64(days), Int64(hours))
    }
    if hours > 0 {
        return String(format: String(localized: "%lldh %lldm"), Int64(hours), Int64(minutes))
    }
    return String(format: String(localized: "%lldm"), Int64(minutes))
}

func formatBytes(_ bytes: UInt64) -> String {
    let tb = Double(bytes) / 1_099_511_627_776
    if tb >= 1 {
        return String(format: "%.1f TB", tb)
    }

    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 {
        return String(format: "%.1f GB", gb)
    }

    let mb = Double(bytes) / 1_048_576
    if mb >= 1 {
        return String(format: "%.0f MB", mb)
    }

    let kb = Double(bytes) / 1_024
    if kb >= 1 {
        return String(format: "%.0f KB", kb)
    }

    return "\(bytes) B"
}

func formatUsedCapacity(_ used: UInt64, total: UInt64) -> String {
    guard total > 0 else {
        return String(format: String(localized: "%@ used"), formatBytes(used))
    }

    return String(format: String(localized: "%@ / %@ used"), formatBytes(used), formatBytes(total))
}
