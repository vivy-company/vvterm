import Foundation

// MARK: - Linux Stats Collector

/// Stats collector for Linux systems using /proc filesystem
struct LinuxStatsCollector: PlatformStatsCollector {

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let cmd = "uname -srm; echo '---SEP---'; hostname; echo '---SEP---'; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1"
        let output = try await client.execute(cmd)
        let parts = output.components(separatedBy: "---SEP---")

        let osInfo = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hostname = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let cpuCores = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1

        return (hostname, osInfo, cpuCores)
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        // Batch multiple /proc reads in one command
        let batchCmd = """
            cat /proc/stat | head -1; echo '---SEP---'; \
            cat /proc/meminfo; echo '---SEP---'; \
            cat /proc/net/dev; echo '---SEP---'; \
            cat /proc/loadavg; echo '---SEP---'; \
            cat /proc/uptime; echo '---SEP---'; \
            ls -d /proc/[0-9]* 2>/dev/null | wc -l
            """
        let batchOutput = try await client.execute(batchCmd)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        // CPU stats
        if sections.count > 0 {
            let prevCpu = context.getCpuValues()
            let cpuResult = parseProcStat(sections[0], prevValues: prevCpu)
            stats.cpuUser = cpuResult.result.user
            stats.cpuSystem = cpuResult.result.system
            stats.cpuIowait = cpuResult.result.iowait
            stats.cpuSteal = cpuResult.result.steal
            stats.cpuIdle = cpuResult.result.idle
            stats.cpuUsage = cpuResult.result.total
            context.updateCpuValues(cpuResult.newValues)
        }

        // Memory stats
        if sections.count > 1 {
            let mem = parseProcMeminfo(sections[1])
            stats.memoryTotal = mem.total
            stats.memoryUsed = mem.used
            stats.memoryFree = mem.free
            stats.memoryCached = mem.cached
            stats.memoryBuffers = mem.buffers
        }

        // Network stats
        if sections.count > 2 {
            let (netRx, netTx) = parseProcNetDev(sections[2])
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

        // Load average
        if sections.count > 3 {
            stats.loadAverage = StatsParsingUtils.parseLoadAverage(sections[3])
        }

        // Uptime
        if sections.count > 4 {
            let uptimeStr = sections[4].trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? "0"
            stats.uptime = TimeInterval(uptimeStr) ?? 0
        }

        // Process count
        if sections.count > 5 {
            stats.processCount = Int(sections[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Volumes (separate command for reliability)
        let dfOutput = try await client.execute("df -BM -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2")
        stats.volumes = parseDfVolumes(dfOutput)

        // Top processes
        let psOutput = try await client.execute("ps aux --sort=-%cpu 2>/dev/null | head -6 || ps aux | head -6")
        stats.topProcesses = parsePs(psOutput)

        stats.timestamp = Date()
        return stats
    }

    // MARK: - Parsers

    private func parseProcStat(_ output: String, prevValues: LinuxCpuValues?) -> (result: CpuResult, newValues: LinuxCpuValues) {
        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard components.count >= 8 else {
            let zeroValues = LinuxCpuValues(user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0)
            return (CpuResult(total: 0, user: 0, system: 0, iowait: 0, steal: 0, idle: 100), zeroValues)
        }

        let user = UInt64(components[1]) ?? 0
        let nice = UInt64(components[2]) ?? 0
        let system = UInt64(components[3]) ?? 0
        let idle = UInt64(components[4]) ?? 0
        let iowait = UInt64(components[5]) ?? 0
        let irq = UInt64(components[6]) ?? 0
        let softirq = UInt64(components[7]) ?? 0
        let steal = components.count > 8 ? (UInt64(components[8]) ?? 0) : 0

        let current = LinuxCpuValues(
            user: user, nice: nice, system: system, idle: idle,
            iowait: iowait, irq: irq, softirq: softirq, steal: steal
        )

        if let prev = prevValues {
            let dUser = Double(current.user - prev.user + current.nice - prev.nice)
            let dSystem = Double(current.system - prev.system + current.irq - prev.irq + current.softirq - prev.softirq)
            let dIdle = Double(current.idle - prev.idle)
            let dIowait = Double(current.iowait - prev.iowait)
            let dSteal = Double(current.steal - prev.steal)

            let total = dUser + dSystem + dIdle + dIowait + dSteal
            if total > 0 {
                return (
                    CpuResult(
                        total: (dUser + dSystem + dIowait + dSteal) / total * 100,
                        user: dUser / total * 100,
                        system: dSystem / total * 100,
                        iowait: dIowait / total * 100,
                        steal: dSteal / total * 100,
                        idle: dIdle / total * 100
                    ),
                    current
                )
            }
        }

        return (CpuResult(total: 0, user: 0, system: 0, iowait: 0, steal: 0, idle: 100), current)
    }

    private func parseProcMeminfo(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64) {
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

    private func parseProcNetDev(_ output: String) -> (rx: UInt64, tx: UInt64) {
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

    private func parseDfVolumes(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 6 else { continue }

            let totalStr = parts[1].replacingOccurrences(of: "M", with: "")
            let usedStr = parts[2].replacingOccurrences(of: "M", with: "")
            let mountPoint = parts[5]

            let total = UInt64(totalStr) ?? 0
            let used = UInt64(usedStr) ?? 0

            if total < 100 { continue }

            volumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: used * 1024 * 1024,
                total: total * 1024 * 1024
            ))
        }

        return volumes
    }

    private func parsePs(_ output: String) -> [ProcessInfo] {
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

// MARK: - CPU Result Helper

struct CpuResult {
    let total: Double
    let user: Double
    let system: Double
    let iowait: Double
    let steal: Double
    let idle: Double
}
