import Foundation

// MARK: - Windows Stats Collector

/// Stats collector for Windows systems via OpenSSH.
/// Prefers cmd.exe-friendly probes on cmd-hosted sessions and PowerShell on PowerShell-hosted sessions.
nonisolated struct WindowsStatsCollector: PlatformStatsCollector {
    private let shellInfoTimeout: Duration = .seconds(5)
    private let cpuTimeout: Duration = .seconds(8)
    private let memoryTimeout: Duration = .seconds(8)
    private let uptimeTimeout: Duration = .seconds(8)
    private let processCountTimeout: Duration = .seconds(6)
    private let networkTimeout: Duration = .seconds(6)
    private let topProcessesTimeout: Duration = .seconds(8)
    private let volumesTimeout: Duration = .seconds(6)
    private let gpuTimeout: Duration = .seconds(8)
    private let periodicProcessLimit = 24

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let environment = await client.remoteEnvironment()
        let hostname = ((try? await executeCMD("hostname", using: client, timeout: shellInfoTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let osInfo = ((try? await executeCMD("ver", using: client, timeout: shellInfoTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        let environmentCPUCount = (try? await executeCMD("echo %NUMBER_OF_PROCESSORS%", using: client, timeout: shellInfoTimeout))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        let wmicCPUCount = (try? await executeCMD(
            "wmic computersystem get NumberOfLogicalProcessors /value",
            using: client,
            timeout: shellInfoTimeout
        )).flatMap { output in
            parseWMICKeyValueOutput(output)["NumberOfLogicalProcessors"]?.first.flatMap(Int.init)
        }
        let cpuCoresCMD = max(wmicCPUCount ?? environmentCPUCount, 1)

        if environment.shellProfile.family == .cmd {
            return (hostname, osInfo, cpuCoresCMD)
        }

        if let cpuCoresOutput = try? await executePowerShell(
            using: client,
            script: "(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors",
            timeout: shellInfoTimeout,
            probeName: "cpu_cores"
        ) {
            let cpuCores = Int(cpuCoresOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? cpuCoresCMD
            return (hostname, osInfo, cpuCores)
        }

        return (hostname, osInfo, cpuCoresCMD)
    }

    func collectProfile(client: SSHClient) async throws -> HardwareProfile {
        let systemInfo = try await getSystemInfo(client: client)

        let cpuOutput = (try? await executePowerShell(
            using: client,
            script: """
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1;
            Write-Output $cpu.Name;
            Write-Output '---SEP---';
            Write-Output $cpu.Manufacturer;
            Write-Output '---SEP---';
            Write-Output $cpu.NumberOfCores;
            Write-Output '---SEP---';
            Write-Output $cpu.NumberOfLogicalProcessors
            """,
            timeout: shellInfoTimeout,
            probeName: "profile_cpu"
        )) ?? ""
        let cpuSections = cpuOutput.components(separatedBy: "---SEP---")

        let memoryOutput = (try? await executePowerShell(
            using: client,
            script: "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory",
            timeout: shellInfoTimeout,
            probeName: "profile_memory"
        )) ?? ""

        let nvidiaGPUOutput = (try? await executePowerShell(
            using: client,
            script: nvidiaSMIQueryScript(fields: "index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,driver_version"),
            timeout: gpuTimeout,
            probeName: "profile_nvidia_gpu"
        )) ?? ""

        let gpuOutput = (try? await executePowerShell(
            using: client,
            script: """
            Get-CimInstance Win32_VideoController | ForEach-Object {
                Write-Output ('{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Name, $_.AdapterCompatibility, $_.AdapterRAM, $_.DriverVersion, $_.PNPDeviceID, $_.Status)
            }
            """,
            timeout: shellInfoTimeout,
            probeName: "profile_gpu"
        )) ?? ""
        let nvidiaGPUs = parseWindowsNvidiaGPUs(nvidiaGPUOutput)
        let wmiGPUs = parseWindowsGPUs(gpuOutput).filter { device in
            guard !nvidiaGPUs.isEmpty else { return true }
            return device.kind != .nvidia
        }

        return HardwareProfile(
            hostname: systemInfo.hostname,
            osInfo: systemInfo.osInfo,
            architecture: "",
            kernelVersion: "",
            cpuModel: section(cpuSections, 0),
            cpuVendor: section(cpuSections, 1),
            cpuCores: Int(section(cpuSections, 2)) ?? 0,
            cpuThreads: Int(section(cpuSections, 3)) ?? systemInfo.cpuCores,
            memoryTotal: UInt64(memoryOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            gpus: nvidiaGPUs + wmiGPUs,
            collectedAt: Date()
        )
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()
        let environment = await client.remoteEnvironment()
        let preferCMD = environment.shellProfile.family == .cmd
        let periodicSnapshot = try? await collectPeriodicStatsPowerShell(client: client)

        if let cpuUsage = try? await collectCPUUsagePowerShell(client: client) {
            applyCPU(cpuUsage, to: &stats)
        } else if preferCMD {
            if let cpuPercent = try? await collectCPUUsageCMD(client: client) {
                applyCPU(cpuPercent, to: &stats)
            }
        } else if let cpuOutput = try? await executePowerShell(
            using: client,
            script: "Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average",
            timeout: cpuTimeout,
            probeName: "cpu_usage"
        ) {
            let cpuPercent = Double(cpuOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            applyCPU(cpuPercent, to: &stats)
        }

        if let memory = periodicSnapshot?.memory {
            stats.memoryTotal = memory.total
            stats.memoryUsed = memory.used
            stats.memoryFree = memory.free
        } else if preferCMD {
            if let memory = try? await collectMemoryCMD(client: client) {
                stats.memoryTotal = memory.total
                stats.memoryUsed = memory.used
                stats.memoryFree = memory.free
            }
        } else if let memoryOutput = try? await executePowerShell(
            using: client,
            script: """
            $os = Get-CimInstance Win32_OperatingSystem;
            Write-Output ($os.TotalVisibleMemorySize * 1024);
            Write-Output '---SEP---';
            Write-Output (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1024);
            Write-Output '---SEP---';
            Write-Output ($os.FreePhysicalMemory * 1024)
            """,
            timeout: memoryTimeout,
            probeName: "memory"
        ) {
            let sections = memoryOutput.components(separatedBy: "---SEP---")
            if sections.count > 0 {
                stats.memoryTotal = UInt64(sections[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            if sections.count > 1 {
                stats.memoryUsed = UInt64(sections[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            if sections.count > 2 {
                stats.memoryFree = UInt64(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        stats.memoryCached = 0
        stats.memoryBuffers = 0

        if let uptime = periodicSnapshot?.uptime {
            stats.uptime = uptime
        } else if preferCMD {
            if let uptime = try? await collectUptimeCMD(client: client) {
                stats.uptime = uptime
            }
        } else if let uptimeOutput = try? await executePowerShell(
            using: client,
            script: """
            $os = Get-CimInstance Win32_OperatingSystem;
            Write-Output ([int]((Get-Date) - $os.LastBootUpTime).TotalSeconds)
            """,
            timeout: uptimeTimeout,
            probeName: "uptime"
        ) {
            stats.uptime = TimeInterval(uptimeOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        if let processCount = periodicSnapshot?.processCount {
            stats.processCount = processCount
        } else if preferCMD, let tasklistOutput = try? await executeCMD("tasklist /NH", using: client, timeout: processCountTimeout) {
            stats.processCount = tasklistOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("INFO:") }
                .count
        } else if let processCountOutput = try? await executePowerShell(
            using: client,
            script: "(Get-Process).Count",
            timeout: processCountTimeout,
            probeName: "process_count"
        ) {
            stats.processCount = Int(processCountOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let network: (rx: UInt64, tx: UInt64)?
        if let periodicNetwork = periodicSnapshot?.network {
            network = periodicNetwork
        } else {
            network = try? await (preferCMD ? collectNetworkStatsCMD(client: client) : collectNetworkStats(client: client))
        }
        if let network {
            let netRx = network.rx
            stats.networkRxTotal = netRx

            let now = Date()
            let (prevRx, prevTx, previousTimestamp) = context.getNetworkPrev()

            let netTx = network.tx
            stats.networkTxTotal = netTx

            let speeds = StatsParsingUtils.calculateNetworkSpeed(
                currentRx: netRx,
                currentTx: netTx,
                prevRx: prevRx,
                prevTx: prevTx,
                prevTimestamp: previousTimestamp,
                now: now
            )
            stats.networkRxSpeed = speeds.rxSpeed
            stats.networkTxSpeed = speeds.txSpeed

            context.updateNetwork(rx: stats.networkRxTotal, tx: netTx, timestamp: Date())
        }

        // Load average (Windows doesn't have this, approximate from CPU)
        stats.loadAverage = (stats.cpuUsage / 100, stats.cpuUsage / 100, stats.cpuUsage / 100)

        let processCollectionTimestamp = Date()
        if context.shouldCollectPeriodicProcesses(
            now: processCollectionTimestamp,
            minimumInterval: 5
        ) {
            var collectedProcesses: [ProcessInfo] = []
            if let processOutput = try? await executePowerShell(
                using: client,
                script: powerShellProcessScript(limit: periodicProcessLimit),
                timeout: topProcessesTimeout,
                probeName: "top_processes"
            ) {
                collectedProcesses = parseProcesses(processOutput)
            } else if preferCMD,
                      let processOutput = try? await executeCMD(
                        "wmic path Win32_PerfFormattedData_PerfProc_Process get IDProcess,Name,PercentProcessorTime,WorkingSet /format:csv",
                        using: client,
                        timeout: topProcessesTimeout
                      ) {
                let logicalProcessors: Int
                if stats.cpuCores > 0 {
                    logicalProcessors = stats.cpuCores
                } else {
                    logicalProcessors = (try? await getSystemInfo(client: client))?.cpuCores ?? 1
                }
                collectedProcesses = Array(parseWMICProcesses(
                    processOutput,
                    memoryTotal: stats.memoryTotal,
                    logicalProcessorCount: max(logicalProcessors, 1)
                ).prefix(periodicProcessLimit))
            }
            context.updatePeriodicProcesses(collectedProcesses, timestamp: processCollectionTimestamp)
        }
        stats.topProcesses = context.getPeriodicProcesses()

        let volumeMetadata = await self.volumeMetadata(client: client, context: context)
        if preferCMD {
            if let volumeOutput = try? await executeCMD(
                "wmic logicaldisk where \"DriveType=3\" get Caption,FileSystem,FreeSpace,Size,VolumeSerialNumber /value",
                using: client,
                timeout: volumesTimeout
            ) {
                stats.volumes = parseWMICVolumes(volumeOutput, metadataByMountPoint: volumeMetadata)
            }
        } else if let volumeOutput = try? await executePowerShell(
            using: client,
            script: "Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Used -gt 0} | ForEach-Object { Write-Output ('{0}|{1}|{2}' -f $_.Name, $_.Used, ($_.Used + $_.Free)) }",
            timeout: volumesTimeout,
            probeName: "volumes"
        ) {
            stats.volumes = parseVolumes(volumeOutput, metadataByMountPoint: volumeMetadata)
        }

        stats.gpuSamples = await collectGPUSamplesIfNeeded(client: client, context: context)

        stats.timestamp = Date()
        return stats
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        if let processOutput = try? await executePowerShell(
            using: client,
            script: powerShellProcessScript(limit: nil),
            timeout: topProcessesTimeout,
            probeName: "top_processes_full"
        ) {
            return parseProcesses(processOutput)
        }

        let memory = (try? await collectMemoryCMD(client: client)) ?? (total: 0, used: 0, free: 0)
        let processOutput = try await executeCMD(
            "wmic path Win32_PerfFormattedData_PerfProc_Process get IDProcess,Name,PercentProcessorTime,WorkingSet /format:csv",
            using: client,
            timeout: topProcessesTimeout
        )
        let logicalProcessors = (try? await getSystemInfo(client: client))?.cpuCores ?? 1
        return parseWMICProcesses(
            processOutput,
            memoryTotal: memory.total,
            logicalProcessorCount: max(logicalProcessors, 1)
        )
    }

    private func applyCPU(_ cpuPercent: Double, to stats: inout ServerStats) {
        let clamped = min(max(cpuPercent, 0), 100)
        stats.cpuUsage = clamped
        stats.cpuUser = clamped * 0.7
        stats.cpuSystem = clamped * 0.3
        stats.cpuIdle = 100 - clamped
        stats.cpuIowait = 0
        stats.cpuSteal = 0
    }

    private func applyCPU(_ cpuUsage: WindowsCPUUsage, to stats: inout ServerStats) {
        let usage = min(max(cpuUsage.usagePercent, 0), 100)
        let user = min(max(cpuUsage.userPercent, 0), 100)
        let system = min(max(cpuUsage.systemPercent, 0), 100)

        stats.cpuUsage = usage
        if user > 0 || system > 0 {
            stats.cpuUser = user
            stats.cpuSystem = system
        } else {
            stats.cpuUser = usage * 0.7
            stats.cpuSystem = usage * 0.3
        }
        stats.cpuIdle = max(100 - usage, 0)
        stats.cpuIowait = 0
        stats.cpuSteal = 0
        stats.cpuCoreSamples = cpuUsage.coreSamples
        if !cpuUsage.coreSamples.isEmpty {
            stats.cpuCores = cpuUsage.coreSamples.count
        }
    }

    private func collectPeriodicStatsPowerShell(client: SSHClient) async throws -> WindowsPeriodicStatsSnapshot {
        let output = try await executePowerShell(
            using: client,
            script: periodicStatsPowerShellScript(),
            timeout: memoryTimeout,
            probeName: "periodic_stats"
        )
        return parsePeriodicStats(output)
    }

    private func collectCPUUsagePowerShell(client: SSHClient) async throws -> WindowsCPUUsage {
        let output = try await executePowerShell(
            using: client,
            script: """
            $counters = @(
              '\\Processor(*)\\% Processor Time',
              '\\Processor(*)\\% User Time',
              '\\Processor(*)\\% Privileged Time'
            );
            $sample = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop;
            $rows = @{};
            $total = @{ Usage = 0.0; User = 0.0; System = 0.0 };
            foreach ($counterSample in $sample.CounterSamples) {
              $instance = [string]$counterSample.InstanceName;
              if ([string]::IsNullOrWhiteSpace($instance)) { continue };
              $path = ([string]$counterSample.Path).ToLowerInvariant();
              $metric = '';
              if ($path.Contains('% processor time')) { $metric = 'Usage' }
              elseif ($path.Contains('% user time')) { $metric = 'User' }
              elseif ($path.Contains('% privileged time')) { $metric = 'System' }
              else { continue };
              $value = [math]::Round([double]$counterSample.CookedValue, 1);
              if ($instance -eq '_total') {
                $total[$metric] = $value;
                continue;
              }
              if ($instance -notmatch '^\\d+$') { continue };
              if (-not $rows.ContainsKey($instance)) {
                $rows[$instance] = @{ Usage = 0.0; User = 0.0; System = 0.0 };
              }
              $rows[$instance][$metric] = $value;
            }
            Write-Output ('TOTAL|{0}|{1}|{2}' -f $total['Usage'], $total['User'], $total['System']);
            $rows.Keys | Sort-Object {[int]$_} | ForEach-Object {
              $row = $rows[$_];
              Write-Output ('CORE|{0}|{1}|{2}|{3}' -f $_, $row['Usage'], $row['User'], $row['System']);
            }
            """,
            timeout: cpuTimeout,
            probeName: "cpu_usage_per_core"
        )
        return parseWindowsCPUUsage(output)
    }

    private func collectNetworkStats(client: SSHClient) async throws -> (rx: UInt64, tx: UInt64) {
        let output = try await executePowerShell(
            using: client,
            script: """
            $stats = Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object {$_.Name -notlike '*Loopback*'};
            $rx = ($stats | Measure-Object -Property ReceivedBytes -Sum).Sum;
            $tx = ($stats | Measure-Object -Property SentBytes -Sum).Sum;
            Write-Output $rx;
            Write-Output '---SEP---';
            Write-Output $tx
            """,
            timeout: networkTimeout,
            probeName: "network"
        )
        let sections = output.components(separatedBy: "---SEP---")
        let rx = sections.indices.contains(0) ? UInt64(sections[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let tx = sections.indices.contains(1) ? UInt64(sections[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        return (rx, tx)
    }

    private func collectCPUUsageCMD(client: SSHClient) async throws -> Double {
        if let output = try? await executeCMD(
            "typeperf \"\\\\Processor(_Total)\\\\% Processor Time\" -sc 1",
            using: client,
            timeout: cpuTimeout
        ), let value = parseTypeperfValue(output) {
            return value
        }

        let output = try await executeCMD(
            "wmic cpu get loadpercentage /value",
            using: client,
            timeout: cpuTimeout
        )
        let values = parseWMICKeyValueOutput(output)["LoadPercentage"]?
            .compactMap { Double($0) } ?? []
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func collectMemoryCMD(client: SSHClient) async throws -> (total: UInt64, used: UInt64, free: UInt64) {
        let output = try await executeCMD(
            "wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value",
            using: client,
            timeout: memoryTimeout
        )
        let values = parseWMICKeyValueOutput(output)
        let freeKB = UInt64(values["FreePhysicalMemory"]?.first ?? "") ?? 0
        let totalKB = UInt64(values["TotalVisibleMemorySize"]?.first ?? "") ?? 0
        let free = freeKB * 1024
        let total = totalKB * 1024
        return (total, total >= free ? total - free : 0, free)
    }

    private func collectUptimeCMD(client: SSHClient) async throws -> TimeInterval {
        let output = try await executeCMD(
            "wmic os get lastbootuptime /value",
            using: client,
            timeout: uptimeTimeout
        )
        let lastBoot = parseWMICKeyValueOutput(output)["LastBootUpTime"]?.first ?? ""
        guard let bootDate = parseWMIDate(lastBoot) else { return 0 }
        return max(Date().timeIntervalSince(bootDate), 0)
    }

    private func collectNetworkStatsCMD(client: SSHClient) async throws -> (rx: UInt64, tx: UInt64) {
        let output = try await executeCMD(
            "netstat -e",
            using: client,
            timeout: networkTimeout
        )
        return parseNetstatInterfaceStats(output)
    }

    private func collectGPUSamplesIfNeeded(client: SSHClient, context: StatsCollectionContext) async -> [GPUSample] {
        guard context.shouldCollectGPU() else {
            return context.getGPUSamples()
        }

        let now = Date()

        if let output = try? await executePowerShell(
            using: client,
            script: nvidiaSMIQueryScript(fields: "index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,driver_version"),
            timeout: gpuTimeout,
            probeName: "gpu_nvidia_samples"
        ) {
            let samples = parseWindowsNvidiaSamples(output, timestamp: now)
            if !samples.isEmpty {
                context.updateGPUSamples(samples, timestamp: now)
                return samples
            }
        }

        if let output = try? await executePowerShell(
            using: client,
            script: windowsGPUCounterScript(),
            timeout: gpuTimeout,
            probeName: "gpu_perf_samples"
        ) {
            let samples = parseWindowsGPUCounterSamples(output, timestamp: now)
            if !samples.isEmpty {
                context.updateGPUSamples(samples, timestamp: now)
                return samples
            }
        }

        context.markGPUCollected(at: now)
        return context.getGPUSamples()
    }

    private func executePowerShell(
        using client: SSHClient,
        script: String,
        timeout: Duration,
        probeName: String
    ) async throws -> String {
        let command = try await powerShellCommand(using: client, script: script)
        return try await execute(command: command, using: client, timeout: timeout)
    }

    private func executeCMD(
        _ command: String,
        using client: SSHClient,
        timeout: Duration
    ) async throws -> String {
        try await execute(command: "cmd.exe /d /c \(command)", using: client, timeout: timeout)
    }

    private func execute(
        command: String,
        using client: SSHClient,
        timeout: Duration
    ) async throws -> String {
        try await client.execute(command, timeout: timeout)
    }

    func volumeMetadata(
        client: SSHClient,
        context: StatsCollectionContext
    ) async -> [String: VolumeCollectionMetadata] {
        if context.beginVolumeMetadataRefresh(for: .windows),
           let output = try? await executePowerShell(
               using: client,
               script: """
               Get-Volume | Where-Object {$_.DriveLetter} | ForEach-Object {
                 Write-Output ('{0}|{1}|{2}' -f ([string]$_.DriveLetter), ([string]$_.FileSystem), ([string]$_.UniqueId))
               }
               """,
               timeout: volumesTimeout,
               probeName: "volume_metadata"
           ) {
            context.updateVolumeMetadata(parseWindowsVolumeMetadata(output), for: .windows)
        }
        return context.volumeMetadata(for: .windows)
    }
}
