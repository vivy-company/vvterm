import Foundation

// MARK: - Linux Stats Collector

/// Stats collector for Linux systems using /proc filesystem
nonisolated struct LinuxStatsCollector: PlatformStatsCollector {
    let bytesPerKiB: UInt64 = 1_024
    let bytesPerMiB: UInt64 = 1_048_576
    let bytesPerGiB: UInt64 = 1_073_741_824
    let bytesPerTiB: UInt64 = 1_099_511_627_776
    let bytesPerPiB: UInt64 = 1_125_899_906_842_624
    private let periodicProcessLimit = 24

    func getSystemInfo(client: SSHClient) async throws -> (hostname: String, osInfo: String, cpuCores: Int) {
        let output = try await client.execute(Self.systemInfoCommand)
        let parts = output.components(separatedBy: "---SEP---")

        let osInfo = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hostname = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let cpuCores = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1

        return (hostname, osInfo, cpuCores)
    }

    func collectProfile(client: SSHClient) async throws -> HardwareProfile {
        let output = try await client.execute(Self.profileCommand, timeout: .seconds(5))
        let sections = output.components(separatedBy: "---SEP---")
        let hostname = sections[safe: 0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let osInfo = sections[safe: 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let architecture = sections[safe: 2]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kernelVersion = sections[safe: 3]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cpu = parseCPUProfile(sections[safe: 4] ?? "")
        let memoryTotal = parseMemTotal(sections[safe: 5] ?? "")
        let nvidiaGPUs = parseNvidiaProfile(sections[safe: 6] ?? "")
        let pciGPUs = parsePCIGPUs(sections[safe: 7] ?? "", existingIDs: Set(nvidiaGPUs.map(\.id)))

        return HardwareProfile(
            hostname: hostname,
            osInfo: osInfo,
            architecture: architecture,
            kernelVersion: kernelVersion,
            cpuModel: cpu.model,
            cpuVendor: cpu.vendor,
            cpuCores: cpu.cores,
            cpuThreads: cpu.threads,
            memoryTotal: memoryTotal,
            gpus: nvidiaGPUs + pciGPUs,
            collectedAt: Date()
        )
    }

    func collectStats(client: SSHClient, context: StatsCollectionContext) async throws -> ServerStats {
        var stats = ServerStats()

        let batchOutput = try await client.execute(Self.statsBatchCommand)
        let sections = batchOutput.components(separatedBy: "---SEP---")

        var missingCpu = true
        var missingMem = true
        var missingNet = true
        var missingLoad = true
        var missingUptime = true
        var missingProcCount = true

        // CPU stats
        if sections.count > 0 {
            if isProcStatValid(sections[0]) {
                let prevCpu = context.getCpuValues()
                let cpuResult = parseProcStat(sections[0], prevValues: prevCpu)
                stats.cpuUser = cpuResult.result.user
                stats.cpuSystem = cpuResult.result.system
                stats.cpuIowait = cpuResult.result.iowait
                stats.cpuSteal = cpuResult.result.steal
                stats.cpuIdle = cpuResult.result.idle
                stats.cpuUsage = cpuResult.result.total
                context.updateCpuValues(cpuResult.newValues)
                let coreResult = parseProcStatCores(sections[0], prevValues: context.getCpuCoreValues())
                stats.cpuCoreSamples = coreResult.samples
                stats.cpuCores = coreResult.samples.count
                context.updateCpuCoreValues(coreResult.newValues)
                missingCpu = false
            }
        }

        // Memory stats
        if sections.count > 1 {
            if isProcMeminfoValid(sections[1]) {
                let mem = parseProcMeminfo(sections[1])
                stats.memoryTotal = mem.total
                stats.memoryUsed = mem.used
                stats.memoryFree = mem.free
                stats.memoryCached = mem.cached
                stats.memoryBuffers = mem.buffers
                missingMem = false
            }
        }

        // Network stats
        if sections.count > 2 {
            if isProcNetDevValid(sections[2]) {
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
                missingNet = false
            }
        }

        // Load average
        if sections.count > 3 {
            let load = StatsParsingUtils.parseLoadAverage(sections[3])
            if load.0 > 0 || load.1 > 0 || load.2 > 0 {
                stats.loadAverage = load
                missingLoad = false
            } else if !sections[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stats.loadAverage = load
                missingLoad = false
            }
        }

        // Uptime
        if sections.count > 4 {
            let uptimeStr = sections[4].trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? "0"
            if let uptime = TimeInterval(uptimeStr), uptime > 0 {
                stats.uptime = uptime
                missingUptime = false
            }
        }

        // Process count
        if sections.count > 5 {
            if let count = Int(sections[5].trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 {
                stats.processCount = count
                missingProcCount = false
            }
        }

        let needsFallback = missingCpu || missingMem || missingNet || missingLoad || missingUptime || missingProcCount
        var fallbackSections: [String] = []

        if needsFallback {
            let fallbackOutput = try await client.execute(Self.fallbackStatsCommand)
            fallbackSections = fallbackOutput.components(separatedBy: "---SEP---")

            let topOutput = fallbackSections.count > 0 ? fallbackSections[0] : ""
            let freeOutput = fallbackSections.count > 1 ? fallbackSections[1] : ""
            let uptimeOutput = fallbackSections.count > 2 ? fallbackSections[2] : ""
            let sysClassNetOutput = fallbackSections.count > 3 ? fallbackSections[3] : ""
            let ipOrIfconfigOutput = fallbackSections.count > 4 ? fallbackSections[4] : ""
            let procCountOutput = fallbackSections.count > 5 ? fallbackSections[5] : ""

            if missingCpu, let cpu = parseTopCpu(topOutput) {
                stats.cpuUser = cpu.user
                stats.cpuSystem = cpu.system
                stats.cpuIowait = cpu.iowait
                stats.cpuSteal = cpu.steal
                stats.cpuIdle = cpu.idle
                stats.cpuUsage = cpu.total
            }

            if missingMem {
                if let mem = parseFreeMemory(freeOutput) ?? parseTopMemory(topOutput) {
                    stats.memoryTotal = mem.total
                    stats.memoryUsed = mem.used
                    stats.memoryFree = mem.free
                    stats.memoryCached = mem.cached
                    stats.memoryBuffers = mem.buffers
                }
            }

            if missingLoad {
                let load = parseUptimeLoadAverage(uptimeOutput)
                if load.0 > 0 || load.1 > 0 || load.2 > 0 {
                    stats.loadAverage = load
                }
            }

            if missingUptime {
                let uptime = parseUptimeSeconds(uptimeOutput)
                if uptime > 0 {
                    stats.uptime = uptime
                }
            }

            if missingNet {
                let netTotals = parseSysClassNet(sysClassNetOutput) ?? parseIpLinkOrIfconfig(ipOrIfconfigOutput)
                if let netTotals {
                    let now = Date()
                    let (prevRx, prevTx, prevTime) = context.getNetworkPrev()
                    let speeds = StatsParsingUtils.calculateNetworkSpeed(
                        currentRx: netTotals.rx, currentTx: netTotals.tx,
                        prevRx: prevRx, prevTx: prevTx,
                        prevTimestamp: prevTime, now: now
                    )
                    stats.networkRxSpeed = speeds.rxSpeed
                    stats.networkTxSpeed = speeds.txSpeed
                    stats.networkRxTotal = netTotals.rx
                    stats.networkTxTotal = netTotals.tx
                    context.updateNetwork(rx: netTotals.rx, tx: netTotals.tx, timestamp: now)
                }
            }

            if missingProcCount, let count = Int(procCountOutput.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 {
                stats.processCount = count
            }
        }

        // Volumes (separate command for reliability). Stable filesystem metadata
        // changes much less often than capacity, so keep it out of the 2-second path.
        let volumeMetadata = await volumeMetadata(client: client, context: context)
        let dfOutput = try await client.execute(Self.volumesCommand)
        stats.volumes = parseDfVolumes(dfOutput, metadataBySource: volumeMetadata)

        // Process CPU is calculated from /proc deltas so it reflects this sampling
        // interval and is normalized to total machine capacity on every platform.
        if let collection = try? await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .linux,
            logicalProcessorCount: max(stats.cpuCores, 1),
            memoryTotal: stats.memoryTotal,
            limit: periodicProcessLimit
        ) {
            stats.topProcesses = collection.processes
            stats.processCount = max(stats.processCount, collection.totalCount)
        }

        // Process count fallback if still missing
        if stats.processCount == 0 {
            let procCount = try await client.execute(Self.processCountCommand)
            stats.processCount = Int(procCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        stats.gpuSamples = await collectGPUSamplesIfNeeded(client: client, context: context)
        stats.timestamp = Date()
        return stats
    }

    func collectProcesses(client: SSHClient, context: StatsCollectionContext) async throws -> [ProcessInfo] {
        let systemInfo = try await getSystemInfo(client: client)
        let memoryOutput = try await client.execute(Self.memoryInfoCommand)
        let memory = parseProcMeminfo(memoryOutput)
        return try await UnixProcessTelemetry.collect(
            client: client,
            context: context,
            platform: .linux,
            logicalProcessorCount: max(systemInfo.cpuCores, 1),
            memoryTotal: memory.total,
            limit: nil
        ).processes
    }

    func collectGPUSamplesIfNeeded(client: SSHClient, context: StatsCollectionContext) async -> [GPUSample] {
        guard context.shouldCollectGPU() else {
            return context.getGPUSamples()
        }

        let now = Date()
        let output = (try? await client.execute(
            Self.gpuSamplesCommand,
            timeout: .seconds(4)
        )) ?? ""
        let samples = parseNvidiaSamples(output, timestamp: now)
        guard !samples.isEmpty else {
            context.markGPUCollected(at: now)
            return context.getGPUSamples()
        }

        context.updateGPUSamples(samples, timestamp: now)
        return samples
    }

    func volumeMetadata(
        client: SSHClient,
        context: StatsCollectionContext
    ) async -> [String: VolumeCollectionMetadata] {
        if context.beginVolumeMetadataRefresh(for: .linux),
           let output = try? await client.execute(
               Self.volumeMetadataCommand,
               timeout: .seconds(5)
           ) {
            context.updateVolumeMetadata(parseLSBLKVolumeMetadata(output), for: .linux)
        }
        return context.volumeMetadata(for: .linux)
    }
}

nonisolated private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
