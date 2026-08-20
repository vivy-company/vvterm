import Foundation

// MARK: - Darwin/macOS Stats Collector

/// Stats collector for macOS/Darwin systems using sysctl, vm_stat, etc.
nonisolated struct DarwinStatsCollector: PlatformStatsCollector {
    private static let periodicProcessLimit = 24

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let cmd = "uname -srm; echo '---SEP---'; hostname; echo '---SEP---'; sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1"
        let output = try await client.execute(cmd)
        let parts = output.components(separatedBy: "---SEP---")

        let osInfo = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hostname = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let cpuCores = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1

        return (hostname, osInfo, cpuCores)
    }

    func collectProfile(client: SSHClient) async throws -> HardwareProfile {
        let profileScript = """
            LC_ALL=C LANG=C; \
            hostname 2>/dev/null; echo '---SEP---'; \
            uname -srm 2>/dev/null; echo '---SEP---'; \
            uname -m 2>/dev/null; echo '---SEP---'; \
            uname -r 2>/dev/null; echo '---SEP---'; \
            sysctl -n machdep.cpu.brand_string 2>/dev/null; echo '---SEP---'; \
            sysctl -n machdep.cpu.vendor 2>/dev/null; echo '---SEP---'; \
            sysctl -n hw.physicalcpu 2>/dev/null; echo '---SEP---'; \
            sysctl -n hw.logicalcpu 2>/dev/null; echo '---SEP---'; \
            sysctl -n hw.memsize 2>/dev/null
            """
        let cmd = RemoteTerminalBootstrap.wrapPOSIXShellCommand(profileScript)
        let output = try await client.execute(cmd, timeout: .seconds(5))
        let sections = output.components(separatedBy: "---SEP---")
        let displayJSON = (try? await client.execute(
            "system_profiler SPDisplaysDataType -json 2>/dev/null",
            timeout: .seconds(6)
        )) ?? ""
        let displayText: String
        if displayJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayText = (try? await client.execute(
                "system_profiler SPDisplaysDataType -detailLevel mini 2>/dev/null || system_profiler SPDisplaysDataType 2>/dev/null || true",
                timeout: .seconds(8)
            )) ?? ""
        } else {
            displayText = ""
        }
        let gpus = parseDisplayProfileJSON(displayJSON)
        let fallbackGPUs = gpus.isEmpty ? parseDisplayProfile(displayText) : []

        return HardwareProfile(
            hostname: section(sections, 0),
            osInfo: section(sections, 1),
            architecture: section(sections, 2),
            kernelVersion: section(sections, 3),
            cpuModel: section(sections, 4),
            cpuVendor: section(sections, 5),
            cpuCores: Int(section(sections, 6)) ?? 0,
            cpuThreads: Int(section(sections, 7)) ?? 0,
            memoryTotal: UInt64(section(sections, 8)) ?? 0,
            gpus: gpus + fallbackGPUs,
            collectedAt: Date()
        )
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        // Batch commands for macOS
        let batchOutput = try await client.execute(Self.statsBatchCommand)
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

        let logicalCPUCount = sections.indices.contains(5)
            ? (Int(sections[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            : 0

        // CPU via top (separate command due to complexity)
        let topOutput = try await client.execute(Self.topCommand)
        let cpu = parseTopCpu(topOutput)
        stats.cpuUser = cpu.user
        stats.cpuSystem = cpu.system
        stats.cpuIdle = cpu.idle
        stats.cpuUsage = cpu.user + cpu.system
        stats.cpuIowait = 0
        stats.cpuSteal = 0
        stats.cpuCores = max(logicalCPUCount, 0)
        if let cpuCoreSamples = await collectCPUCoreSamplesIfAvailable(client: client, context: context),
           !cpuCoreSamples.isEmpty {
            stats.cpuCoreSamples = cpuCoreSamples
            stats.cpuCores = max(stats.cpuCores, cpuCoreSamples.count)
        }

        if let collection = try? await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .darwin,
            logicalProcessorCount: max(logicalCPUCount, 1),
            memoryTotal: totalMem,
            limit: Self.periodicProcessLimit
        ) {
            stats.topProcesses = collection.processes
            stats.processCount = collection.totalCount
        }

        // Volumes
        let dfOutput = try await client.execute(Self.dfCommand)
        let volumeMetadata = await volumeMetadata(
            client: client,
            context: context,
            sources: dfSources(dfOutput)
        )
        stats.volumes = parseDf(dfOutput, metadataBySource: volumeMetadata)

        stats.timestamp = Date()
        return stats
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        let systemInfo = try await getSystemInfo(client: client)
        let totalMemoryOutput = try await client.execute("sysctl -n hw.memsize 2>/dev/null")
        let totalMemory = UInt64(totalMemoryOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return try await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .darwin,
            logicalProcessorCount: max(systemInfo.cpuCores, 1),
            memoryTotal: totalMemory,
            limit: nil
        ).processes
    }

    private func collectCPUCoreSamplesIfAvailable(
        client: SSHClient,
        context: StatsCollectionContext
    ) async -> [CPUCoreSample]? {
        guard let output = try? await client.execute(Self.processorLoadCommand, timeout: .seconds(12)) else {
            return nil
        }

        let parsed = parseProcessorLoadOutput(output, previousValues: context.getCpuCoreValues())
        context.updateCpuCoreValues(parsed.newValues)
        return parsed.samples
    }

    private func volumeMetadata(
        client: SSHClient,
        context: StatsCollectionContext,
        sources: [String]
    ) async -> [String: VolumeCollectionMetadata] {
        guard context.beginVolumeMetadataRefresh(for: .darwin) else {
            return context.volumeMetadata(for: .darwin)
        }

        var metadata = context.volumeMetadata(for: .darwin)
        if let output = try? await client.execute(
            Self.diskutilListCommand,
            timeout: .seconds(6)
        ) {
            metadata.merge(parseDiskutilVolumeMetadata(output)) { _, fresh in fresh }
        }

        for source in sources where metadata[source]?.stableIdentifier == nil {
            guard isSafeDarwinDevicePath(source),
                  let output = try? await client.execute(
                      RemoteTerminalBootstrap.wrapPOSIXShellCommand(
                          "export LC_ALL=C LANG=C; /usr/sbin/diskutil info -plist \(RemoteTerminalBootstrap.shellQuoted(source)) 2>/dev/null"
                      ),
                      timeout: .seconds(4)
                  ) else { continue }
            metadata.merge(parseDiskutilVolumeMetadata(output)) { _, fresh in fresh }
        }

        context.updateVolumeMetadata(metadata, for: .darwin)
        return context.volumeMetadata(for: .darwin)
    }
}
