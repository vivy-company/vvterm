import Foundation

// MARK: - FreeBSD Stats Collector

/// Stats collector for FreeBSD systems (including TrueNAS, pfSense, OPNsense)
struct FreeBSDStatsCollector: PlatformStatsCollector {

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

        // Batch commands for FreeBSD
        let batchCmd = """
            sysctl -n vm.loadavg 2>/dev/null || uptime | sed 's/.*load averages: //'; echo '---SEP---'; \
            sysctl -n kern.boottime; echo '---SEP---'; \
            sysctl -n hw.physmem; echo '---SEP---'; \
            vmstat -H 2>/dev/null || vmstat; echo '---SEP---'; \
            netstat -ibn | head -20; echo '---SEP---'; \
            ps -axo pid,pcpu,pmem,comm | head -6
            """
        let batchOutput = try await client.execute(batchCmd)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        // Load average
        if sections.count > 0 {
            stats.loadAverage = StatsParsingUtils.parseLoadAverage(sections[0])
        }

        // Uptime from boot time
        if sections.count > 1 {
            stats.uptime = parseBootTime(sections[1])
        }

        // Total memory
        var totalMem: UInt64 = 0
        if sections.count > 2 {
            totalMem = UInt64(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Memory via vmstat and sysctl
        if sections.count > 3 {
            let mem = try await parseMemory(client: client, vmstatOutput: sections[3], totalMemory: totalMem)
            stats.memoryTotal = mem.total
            stats.memoryUsed = mem.used
            stats.memoryFree = mem.free
            stats.memoryCached = mem.cached
            stats.memoryBuffers = mem.buffers
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

        // CPU via vmstat or top
        let cpuOutput = try await client.execute("vmstat 1 2 | tail -1")
        let cpu = parseVmstatCpu(cpuOutput)
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
        // FreeBSD format: { sec = 1234567890, usec = 123456 }
        if let secRange = output.range(of: "sec = "),
           let commaRange = output.range(of: ",", range: secRange.upperBound..<output.endIndex) {
            let secStr = String(output[secRange.upperBound..<commaRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let bootTime = TimeInterval(secStr) {
                return StatsParsingUtils.uptimeFromBootTime(bootTime)
            }
        }
        return 0
    }

    private func parseMemory(client: SSHClient, vmstatOutput: String, totalMemory: UInt64) async throws -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64) {
        // Get detailed memory info from sysctl
        let memCmd = """
            sysctl -n vm.stats.vm.v_page_size; echo '---M---'; \
            sysctl -n vm.stats.vm.v_free_count; echo '---M---'; \
            sysctl -n vm.stats.vm.v_inactive_count; echo '---M---'; \
            sysctl -n vm.stats.vm.v_cache_count 2>/dev/null || echo 0; echo '---M---'; \
            sysctl -n vfs.bufspace
            """
        let memOutput = try await client.execute(memCmd)
        let parts = memOutput.components(separatedBy: "---M---")

        let pageSize = parts.count > 0 ? UInt64(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4096 : 4096
        let freePages = parts.count > 1 ? UInt64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let inactivePages = parts.count > 2 ? UInt64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let cachePages = parts.count > 3 ? UInt64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let buffers = parts.count > 4 ? UInt64(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0

        let free = freePages * pageSize
        let cached = (inactivePages + cachePages) * pageSize
        let used = totalMemory - free - cached

        return (totalMemory, used, free, cached, buffers)
    }

    private func parseNetstat(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // FreeBSD format: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes
            guard parts.count >= 10 else { continue }

            let iface = parts[0]
            if iface.hasPrefix("lo") || iface.hasPrefix("pflog") || iface.hasPrefix("enc") { continue }

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

    private func parseVmstatCpu(_ output: String) -> (user: Double, system: Double, idle: Double) {
        // vmstat output last line: r b w avm fre  flt  re  pi  po  fr  sr da0 in  sy  cs us sy id
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Last 3 columns are typically us, sy, id
        guard parts.count >= 3 else { return (0, 0, 100) }

        let idle = Double(parts[parts.count - 1]) ?? 100
        let system = Double(parts[parts.count - 2]) ?? 0
        let user = Double(parts[parts.count - 3]) ?? 0

        return (user, system, idle)
    }

    private func parseDf(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 6 else { continue }

            let totalMB = UInt64(parts[1]) ?? 0
            let usedMB = UInt64(parts[2]) ?? 0
            let mountPoint = parts[5]

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
