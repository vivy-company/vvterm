import Foundation

enum StatsPreviewFixture {
    static let now = Date(timeIntervalSinceReferenceDate: 804_000_000)
    static let gigabyte = UInt64(1_073_741_824)

    static var stats: ServerStats {
        let gpu = GPUDevice(
            id: "gpu-0",
            name: "NVIDIA RTX 4090",
            vendor: "NVIDIA",
            kind: .nvidia,
            driverVersion: "555.42",
            memoryTotal: 24 * gigabyte,
            source: .nvidiaSMI
        )
        let secondGPU = GPUDevice(
            id: "gpu-1",
            name: "NVIDIA RTX 4090",
            vendor: "NVIDIA",
            kind: .nvidia,
            driverVersion: "555.42",
            memoryTotal: 24 * gigabyte,
            source: .nvidiaSMI
        )

        var stats = ServerStats()
        stats.hostname = "demo-server"
        stats.osInfo = "Ubuntu 24.04 LTS"
        stats.hardware = HardwareProfile(
            hostname: "demo-server",
            osInfo: "Ubuntu 24.04 LTS",
            architecture: "arm64",
            kernelVersion: "6.8.0",
            cpuModel: "Ampere Altra",
            cpuVendor: "Ampere",
            cpuCores: 8,
            cpuThreads: 8,
            memoryTotal: 16 * gigabyte,
            gpus: [gpu, secondGPU],
            collectedAt: now
        )
        stats.cpuCores = 8
        stats.cpuUsage = 42
        stats.cpuUser = 31
        stats.cpuSystem = 11
        stats.cpuIowait = 1
        stats.cpuSteal = 0
        stats.cpuIdle = 58
        stats.cpuCoreSamples = [
            CPUCoreSample(identifier: "cpu0", displayName: "CPU 1", usagePercent: 24, userPercent: 17, systemPercent: 6, iowaitPercent: 1, stealPercent: 0, idlePercent: 76),
            CPUCoreSample(identifier: "cpu1", displayName: "CPU 2", usagePercent: 67, userPercent: 52, systemPercent: 14, iowaitPercent: 1, stealPercent: 0, idlePercent: 33),
            CPUCoreSample(identifier: "cpu2", displayName: "CPU 3", usagePercent: 42, userPercent: 31, systemPercent: 10, iowaitPercent: 1, stealPercent: 0, idlePercent: 58),
            CPUCoreSample(identifier: "cpu3", displayName: "CPU 4", usagePercent: 18, userPercent: 12, systemPercent: 5, iowaitPercent: 1, stealPercent: 0, idlePercent: 82)
        ]
        stats.memoryTotal = 16 * gigabyte
        stats.memoryUsed = UInt64(Double(16 * gigabyte) * 0.68)
        stats.memoryFree = stats.memoryTotal - stats.memoryUsed
        stats.memoryCached = UInt64(Double(16 * gigabyte) * 0.18)
        stats.memoryBuffers = UInt64(Double(16 * gigabyte) * 0.04)
        stats.networkRxSpeed = 12 * 1_048_576
        stats.networkTxSpeed = 4 * 1_048_576
        stats.networkRxTotal = 382 * gigabyte
        stats.networkTxTotal = 147 * gigabyte
        stats.volumes = [
            VolumeInfo(mountPoint: "/", used: 681 * gigabyte, total: 926 * gigabyte),
            VolumeInfo(mountPoint: "/srv/models", used: 824 * gigabyte, total: 1_862 * gigabyte),
            VolumeInfo(mountPoint: "/Volumes/backup", used: 232 * gigabyte, total: 1_862 * gigabyte)
        ]
        stats.loadAverage = (0.82, 1.14, 1.04)
        stats.uptime = 178_200
        stats.processCount = 638
        stats.topProcesses = [
            ProcessInfo(pid: 1124, name: "python", cpuPercent: 62.4, memoryPercent: 18.2),
            ProcessInfo(pid: 2048, name: "ollama", cpuPercent: 18.0, memoryPercent: 24.9),
            ProcessInfo(pid: 364, name: "logd", cpuPercent: 1.5, memoryPercent: 0.2),
            ProcessInfo(pid: 1, name: "launchd", cpuPercent: 1.0, memoryPercent: 0.1)
        ]
        stats.docker = DockerStats(
            availability: .available,
            containers: [
                DockerContainer(
                    id: "f0a1b2c3d4e5f6",
                    name: "ollama",
                    image: "ollama/ollama:latest",
                    command: "ollama serve",
                    state: .running,
                    status: "Up 2 hours (healthy)",
                    health: .healthy,
                    createdAt: "2026-07-06 09:00:00 +0000 UTC",
                    runningFor: "2 hours",
                    ports: "11434/tcp",
                    cpuPercent: 42,
                    memoryPercent: 28,
                    memoryUsed: 4 * gigabyte,
                    memoryLimit: 14 * gigabyte,
                    networkRx: 820 * 1_048_576,
                    networkTx: 210 * 1_048_576,
                    blockRead: 18 * gigabyte,
                    blockWrite: 6 * gigabyte,
                    pids: 22
                ),
                DockerContainer(
                    id: "a0b1c2d3e4f5a6",
                    name: "postgres",
                    image: "postgres:16",
                    command: "docker-entrypoint.sh",
                    state: .running,
                    status: "Up 3 days",
                    health: .none,
                    createdAt: "2026-07-03 12:00:00 +0000 UTC",
                    runningFor: "3 days",
                    ports: "5432/tcp",
                    cpuPercent: 6,
                    memoryPercent: 12,
                    memoryUsed: 1 * gigabyte,
                    memoryLimit: 8 * gigabyte,
                    networkRx: 220 * 1_048_576,
                    networkTx: 180 * 1_048_576,
                    blockRead: 9 * gigabyte,
                    blockWrite: 24 * gigabyte,
                    pids: 16
                ),
                DockerContainer(
                    id: "b0c1d2e3f4a5b6",
                    name: "redis",
                    image: "redis:7",
                    command: "redis-server",
                    state: .exited,
                    status: "Exited (0) 1 hour ago",
                    health: .none,
                    createdAt: "2026-07-01 10:00:00 +0000 UTC",
                    runningFor: "",
                    ports: "6379/tcp",
                    cpuPercent: 0,
                    memoryPercent: 0,
                    memoryUsed: nil,
                    memoryLimit: nil,
                    networkRx: nil,
                    networkTx: nil,
                    blockRead: nil,
                    blockWrite: nil,
                    pids: nil
                )
            ],
            timestamp: now
        )
        stats.gpuSamples = [
            GPUSample(
                deviceID: gpu.id,
                utilizationPercent: 76,
                memoryUsed: 14 * gigabyte,
                memoryTotal: gpu.memoryTotal,
                temperatureCelsius: 62,
                powerWatts: 284,
                processes: [
                    GPUProcess(pid: 1124, name: "python", memoryUsed: 12 * gigabyte, utilizationPercent: 71)
                ],
                source: .nvidiaSMI,
                timestamp: now
            ),
            GPUSample(
                deviceID: secondGPU.id,
                utilizationPercent: 41,
                memoryUsed: 8 * gigabyte,
                memoryTotal: secondGPU.memoryTotal,
                temperatureCelsius: 55,
                powerWatts: 176,
                processes: [
                    GPUProcess(pid: 2048, name: "ollama", memoryUsed: 7 * gigabyte, utilizationPercent: 38)
                ],
                source: .nvidiaSMI,
                timestamp: now
            )
        ]
        stats.timestamp = now
        return stats
    }

    static var cpuHistory: [StatsPoint] {
        makeHistory([18, 24, 52, 47, 42, 67, 58, 41, 44, 42])
    }

    static var memoryHistory: [StatsPoint] {
        makeHistory([54, 56, 59, 60, 64, 65, 66, 70, 69, 68])
    }

    static var networkRxHistory: [StatsPoint] {
        makeHistory([1, 2, 4, 11, 7, 12, 8, 5, 9, 12].map { Double($0) * 1_048_576 })
    }

    static var networkTxHistory: [StatsPoint] {
        makeHistory([0.4, 1.2, 2.0, 3.8, 2.4, 4.2, 2.8, 1.7, 3.0, 4.0].map { $0 * 1_048_576 })
    }

    static var gpuHistories: [String: [StatsPoint]] {
        [
            "gpu-0": makeHistory([28, 36, 61, 79, 71, 84, 76, 66, 72, 76]),
            "gpu-1": makeHistory([11, 18, 27, 45, 39, 52, 47, 44, 38, 41])
        ]
    }

    static var dockerCPUHistory: [StatsPoint] {
        makeHistory([12, 18, 26, 48, 35, 55, 42, 38, 51, 48])
    }

    static var dockerMemoryHistory: [StatsPoint] {
        makeHistory([20, 22, 24, 28, 30, 31, 32, 35, 37, 36])
    }

    static var presentationSnapshot: ServerStatsPresentationSnapshot {
        ServerStatsPresentationSnapshot(
            stats: stats,
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            gpuHistories: gpuHistories,
            networkRxHistory: networkRxHistory,
            networkTxHistory: networkTxHistory,
            dockerCPUHistory: dockerCPUHistory,
            dockerMemoryHistory: dockerMemoryHistory
        )
    }

    private static func makeHistory(_ values: [Double]) -> [StatsPoint] {
        values.enumerated().map { index, value in
            StatsPoint(
                timestamp: now.addingTimeInterval(Double(index - values.count) * 30),
                value: value
            )
        }
    }
}
