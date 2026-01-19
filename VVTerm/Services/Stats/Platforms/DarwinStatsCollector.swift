import Foundation

// MARK: - Darwin/macOS Stats Collector

/// Stats collector for macOS/Darwin systems using sysctl, vm_stat, etc.
struct DarwinStatsCollector: PlatformStatsCollector {

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let cmd = "uname -srm; echo '---SEP---'; hostname; echo '---SEP---'; sysctl -n hw.ncpu 2>/dev/null || echo 1"
        let output = try await client.execute(cmd)
        let parts = output.components(separatedBy: "---SEP---")

        let osInfo = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hostname = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let cpuCores = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1

        return (hostname, osInfo, cpuCores)
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        // Batch commands for macOS
        let batchCmd = """
            sysctl -n vm.loadavg 2>/dev/null || uptime | sed 's/.*load average[s]*: //'; echo '---SEP---'; \
            sysctl -n kern.boottime; echo '---SEP---'; \
            sysctl -n hw.memsize; echo '---SEP---'; \
            vm_stat; echo '---SEP---'; \
            netstat -ib | head -20; echo '---SEP---'; \
            ps -Axo pid,pcpu,pmem,comm | head -6
            """
        let batchOutput = try await client.execute(batchCmd)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        // Load average (format: { 1.23 4.56 7.89 })
        if sections.count > 0 {
            stats.loadAverage = StatsParsingUtils.parseLoadAverage(sections[0])
        }

        // Uptime from boot time
        if sections.count > 1 {
            stats.uptime = parseBootTime(sections[1])
        }

        // Total memory from sysctl hw.memsize
        var totalMem: UInt64 = 0
        if sections.count > 2 {
            totalMem = UInt64(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Memory via vm_stat
        if sections.count > 3 {
            let mem = parseVmStat(sections[3], totalMemory: totalMem)
            stats.memoryTotal = mem.total
            stats.memoryUsed = mem.used
            stats.memoryFree = mem.free
            stats.memoryCached = mem.cached
            stats.memoryBuffers = 0
        }

        // Network via netstat
        if sections.count > 4 {
            let (netRx, netTx) = parseNetstat(sections[4])
            let now = Date()
            let (prevRx, prevTx, prevTime) = context.getNetworkPrev()

            let speeds = StatsParsingUtils.calculateNetworkSpeed(
                currentRx: netRx, currentTx: netTx,
                prevRx: prevRx, prevTx: prevTx,
                prevTimestamp: prevTime, now: now
            )
            stats.networkRxSpeed = speeds.rxSpeed
            stats.networkTxSpeed = speeds.txSpeed
            stats.networkRxTotal = netRx
            stats.networkTxTotal = netTx

            context.updateNetwork(rx: netRx, tx: netTx, timestamp: now)
        }

        // Processes
        if sections.count > 5 {
            stats.topProcesses = parsePs(sections[5])
        }

        // CPU via top (separate command due to complexity)
        let topOutput = try await client.execute("top -l 1 -n 0 -s 0 2>/dev/null | grep 'CPU usage' || echo 'CPU usage: 0% user, 0% sys, 100% idle'")
        let cpu = parseTopCpu(topOutput)
        stats.cpuUser = cpu.user
        stats.cpuSystem = cpu.system
        stats.cpuIdle = cpu.idle
        stats.cpuUsage = cpu.user + cpu.system
        stats.cpuIowait = 0
        stats.cpuSteal = 0

        // Process count
        let procCount = try await client.execute("ps -ax | wc -l")
        stats.processCount = Int(procCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        // Volumes
        let dfOutput = try await client.execute("df -m 2>/dev/null | grep -E '^/dev' | head -10")
        stats.volumes = parseDf(dfOutput)

        stats.timestamp = Date()
        return stats
    }

    // MARK: - Parsers

    private func parseBootTime(_ output: String) -> TimeInterval {
        // Format: { sec = 1234567890, usec = 123456 } ...
        if let secRange = output.range(of: "sec = "),
           let commaRange = output.range(of: ",", range: secRange.upperBound..<output.endIndex) {
            let secStr = String(output[secRange.upperBound..<commaRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let bootTime = TimeInterval(secStr) {
                return StatsParsingUtils.uptimeFromBootTime(bootTime)
            }
        }
        return 0
    }

    private func parseVmStat(_ output: String, totalMemory: UInt64) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64) {
        var pagesFree: UInt64 = 0
        var pagesActive: UInt64 = 0
        var pagesInactive: UInt64 = 0
        var pagesSpeculative: UInt64 = 0
        var pagesWired: UInt64 = 0
        var pagesCompressed: UInt64 = 0
        var pagesCached: UInt64 = 0
        var pageSize: UInt64 = 16384 // Default to 16KB (Apple Silicon)

        for line in output.components(separatedBy: .newlines) {
            // Extract page size from header
            if line.contains("page size of") {
                if let range = line.range(of: "page size of "),
                   let endRange = line.range(of: " bytes", range: range.upperBound..<line.endIndex) {
                    let sizeStr = String(line[range.upperBound..<endRange.lowerBound])
                    pageSize = UInt64(sizeStr) ?? 16384
                }
                continue
            }

            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let valueStr = parts[1].replacingOccurrences(of: ".", with: "")
            let value = UInt64(valueStr) ?? 0

            switch parts[0] {
            case "Pages free": pagesFree = value
            case "Pages active": pagesActive = value
            case "Pages inactive": pagesInactive = value
            case "Pages speculative": pagesSpeculative = value
            case "Pages wired down": pagesWired = value
            case "Pages occupied by compressor": pagesCompressed = value
            case "File-backed pages": pagesCached = value
            default: break
            }
        }

        let total = totalMemory > 0 ? totalMemory : (pagesFree + pagesActive + pagesInactive + pagesSpeculative + pagesWired + pagesCompressed) * pageSize
        let free = (pagesFree + pagesSpeculative) * pageSize
        let used = (pagesActive + pagesWired + pagesCompressed) * pageSize
        let cached = (pagesInactive + pagesCached) * pageSize

        return (total, used, free, cached)
    }

    private func parseNetstat(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes
            guard parts.count >= 10 else { continue }

            let iface = parts[0]
            if iface.hasPrefix("lo") || iface.hasPrefix("gif") || iface.hasPrefix("stf") { continue }

            if let ibytes = UInt64(parts[6]), let obytes = UInt64(parts[9]) {
                totalRx += ibytes
                totalTx += obytes
            }
        }

        return (totalRx, totalTx)
    }

    private func parsePs(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { continue }

            let pid = Int(parts[0]) ?? 0
            let cpu = Double(parts[1]) ?? 0
            let mem = Double(parts[2]) ?? 0
            let name = parts[3...].joined(separator: " ")

            processes.append(ProcessInfo(pid: pid, name: name, cpuPercent: cpu, memoryPercent: mem))
        }

        return processes
    }

    private func parseTopCpu(_ output: String) -> (user: Double, system: Double, idle: Double) {
        var user = 0.0
        var system = 0.0
        var idle = 100.0

        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")

        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("user") {
                let numStr = trimmed.replacingOccurrences(of: "CPU usage:", with: "")
                    .replacingOccurrences(of: "% user", with: "")
                    .trimmingCharacters(in: .whitespaces)
                user = Double(numStr) ?? 0
            } else if trimmed.contains("sys") {
                let numStr = trimmed.replacingOccurrences(of: "% sys", with: "")
                    .trimmingCharacters(in: .whitespaces)
                system = Double(numStr) ?? 0
            } else if trimmed.contains("idle") {
                let numStr = trimmed.replacingOccurrences(of: "% idle", with: "")
                    .trimmingCharacters(in: .whitespaces)
                idle = Double(numStr) ?? 100
            }
        }

        return (user, system, idle)
    }

    private func parseDf(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted
            guard parts.count >= 9 else { continue }

            let totalMB = UInt64(parts[1]) ?? 0
            let usedMB = UInt64(parts[2]) ?? 0
            let mountPoint = parts[8]

            if totalMB < 100 { continue }

            volumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: usedMB * 1024 * 1024,
                total: totalMB * 1024 * 1024
            ))
        }

        return volumes
    }
}
