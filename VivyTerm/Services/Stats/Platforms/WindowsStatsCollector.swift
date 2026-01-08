import Foundation

// MARK: - Windows Stats Collector

/// Stats collector for Windows systems via OpenSSH (uses PowerShell)
struct WindowsStatsCollector: PlatformStatsCollector {

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        // Use PowerShell to get system info
        let cmd = """
            powershell -Command "[System.Environment]::OSVersion.VersionString; \
            Write-Output '---SEP---'; \
            hostname; \
            Write-Output '---SEP---'; \
            (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors"
            """
        let output = try await client.execute(cmd)
        let parts = output.components(separatedBy: "---SEP---")

        let osInfo = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hostname = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let cpuCores = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1

        return (hostname, osInfo, cpuCores)
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        // Batch PowerShell commands
        let batchCmd = """
            powershell -Command " \
            $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average; \
            $os = Get-CimInstance Win32_OperatingSystem; \
            $mem = @{Total=$os.TotalVisibleMemorySize*1024; Free=$os.FreePhysicalMemory*1024; Used=($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)*1024}; \
            $uptime = (Get-Date) - $os.LastBootUpTime; \
            $procs = (Get-Process).Count; \
            $net = Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object {$_.Name -notlike '*Loopback*'} | Measure-Object -Property ReceivedBytes,SentBytes -Sum; \
            Write-Output $cpu; \
            Write-Output '---SEP---'; \
            Write-Output ($mem.Total); \
            Write-Output '---SEP---'; \
            Write-Output ($mem.Used); \
            Write-Output '---SEP---'; \
            Write-Output ($mem.Free); \
            Write-Output '---SEP---'; \
            Write-Output ([int]$uptime.TotalSeconds); \
            Write-Output '---SEP---'; \
            Write-Output $procs; \
            Write-Output '---SEP---'; \
            $rxSum = ($net | Where-Object {$_.Property -eq 'ReceivedBytes'}).Sum; \
            $txSum = ($net | Where-Object {$_.Property -eq 'SentBytes'}).Sum; \
            Write-Output $rxSum; \
            Write-Output '---SEP---'; \
            Write-Output $txSum \
            "
            """

        let batchOutput = try await client.execute(batchCmd)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        // CPU
        if sections.count > 0 {
            let cpuPercent = Double(sections[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            stats.cpuUsage = cpuPercent
            stats.cpuUser = cpuPercent * 0.7 // Approximate split
            stats.cpuSystem = cpuPercent * 0.3
            stats.cpuIdle = 100 - cpuPercent
            stats.cpuIowait = 0
            stats.cpuSteal = 0
        }

        // Memory total
        if sections.count > 1 {
            stats.memoryTotal = UInt64(sections[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Memory used
        if sections.count > 2 {
            stats.memoryUsed = UInt64(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Memory free
        if sections.count > 3 {
            stats.memoryFree = UInt64(sections[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        stats.memoryCached = 0
        stats.memoryBuffers = 0

        // Uptime
        if sections.count > 4 {
            stats.uptime = TimeInterval(sections[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Process count
        if sections.count > 5 {
            stats.processCount = Int(sections[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Network RX
        if sections.count > 6 {
            let netRx = UInt64(sections[6].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            stats.networkRxTotal = netRx

            let now = Date()
            let (prevRx, prevTx, prevTime) = context.getNetworkPrev()

            if let prevTime = prevTime, prevRx > 0 || prevTx > 0 {
                let elapsed = now.timeIntervalSince(prevTime)
                if elapsed > 0 {
                    stats.networkRxSpeed = UInt64(Double(netRx - prevRx) / elapsed)
                }
            }
        }

        // Network TX
        if sections.count > 7 {
            let netTx = UInt64(sections[7].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            stats.networkTxTotal = netTx

            let now = Date()
            let (prevRx, prevTx, prevTime) = context.getNetworkPrev()

            if let prevTime = prevTime, prevTx > 0 {
                let elapsed = now.timeIntervalSince(prevTime)
                if elapsed > 0 {
                    stats.networkTxSpeed = UInt64(Double(netTx - prevTx) / elapsed)
                }
            }

            context.updateNetwork(rx: stats.networkRxTotal, tx: netTx, timestamp: Date())
        }

        // Load average (Windows doesn't have this, approximate from CPU)
        stats.loadAverage = (stats.cpuUsage / 100, stats.cpuUsage / 100, stats.cpuUsage / 100)

        // Top processes (separate command)
        let psCmd = """
            powershell -Command "Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object { Write-Output ('{0}|{1}|{2}|{3}' -f $_.Id, $_.ProcessName, [math]::Round($_.CPU,1), [math]::Round($_.WorkingSet64/1MB,1)) }"
            """
        let psOutput = try await client.execute(psCmd)
        stats.topProcesses = parseProcesses(psOutput)

        // Volumes
        let dfCmd = """
            powershell -Command "Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Used -gt 0} | ForEach-Object { Write-Output ('{0}|{1}|{2}' -f $_.Name, $_.Used, ($_.Used + $_.Free)) }"
            """
        let dfOutput = try await client.execute(dfCmd)
        stats.volumes = parseVolumes(dfOutput)

        stats.timestamp = Date()
        return stats
    }

    // MARK: - Parsers

    private func parseProcesses(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 4 else { continue }

            let pid = Int(parts[0]) ?? 0
            let name = parts[1]
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0

            processes.append(ProcessInfo(pid: pid, name: name, cpuPercent: cpu, memoryPercent: mem))
        }

        return processes
    }

    private func parseVolumes(_ output: String) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 3 else { continue }

            let mountPoint = parts[0] + ":\\"
            let used = UInt64(parts[1]) ?? 0
            let total = UInt64(parts[2]) ?? 0

            if total < 100 * 1024 * 1024 { continue } // Skip volumes < 100MB

            volumes.append(VolumeInfo(
                mountPoint: mountPoint,
                used: used,
                total: total
            ))
        }

        return volumes
    }
}
