import Foundation

nonisolated extension WindowsStatsCollector {
    // MARK: - Parsers

    func parsePeriodicStats(_ output: String) -> WindowsPeriodicStatsSnapshot {
        var memory: (total: UInt64, used: UInt64, free: UInt64)?
        var uptime: TimeInterval?
        var processCount: Int?
        var network: (rx: UInt64, tx: UInt64)?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let fields = line.components(separatedBy: "|")
            switch fields.first {
            case "MEMORY" where fields.count == 4:
                guard
                    let total = UInt64(fields[1]),
                    let used = UInt64(fields[2]),
                    let free = UInt64(fields[3]),
                    used <= total,
                    free <= total
                else {
                    continue
                }
                memory = (total, used, free)
            case "UPTIME" where fields.count == 2:
                if let seconds = UInt64(fields[1]) {
                    uptime = TimeInterval(seconds)
                }
            case "PROCESS_COUNT" where fields.count == 2:
                if let count = Int(fields[1]), count >= 0 {
                    processCount = count
                }
            case "NETWORK" where fields.count == 3:
                if let rx = UInt64(fields[1]), let tx = UInt64(fields[2]) {
                    network = (rx, tx)
                }
            default:
                continue
            }
        }

        return WindowsPeriodicStatsSnapshot(
            memory: memory,
            uptime: uptime,
            processCount: processCount,
            network: network
        )
    }

    func parseProcesses(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 4 else { continue }

            let pid = Int(parts[0]) ?? 0
            let name = parts[1]
            let cpu = parseWindowsDouble(parts[2]) ?? 0
            let mem = parseWindowsDouble(parts[3]) ?? 0
            let memoryBytes = parts.count > 4 ? UInt64(parts[4]) : nil

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: min(max(cpu.isFinite ? cpu : 0, 0), 100),
                memoryPercent: min(max(mem.isFinite ? mem : 0, 0), 100),
                memoryBytes: memoryBytes
            ))
        }

        return processes
    }

    func parseVolumes(
        _ output: String,
        metadataByMountPoint: [String: VolumeCollectionMetadata] = [:]
    ) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 3 else { continue }

            let mountPoint = normalizedWindowsMountPoint(parts[0])
            let used = UInt64(parts[1]) ?? 0
            let total = UInt64(parts[2]) ?? 0
            let metadata = metadataByMountPoint[mountPoint]

            if total < 100 * 1024 * 1024 { continue } // Skip volumes < 100MB

            volumes.append(VolumeInfo(
                platform: .windows,
                mountPoint: mountPoint,
                source: mountPoint,
                fileSystem: metadata?.fileSystem ?? "",
                stableIdentifier: metadata?.stableIdentifier,
                used: used,
                total: total
            ))
        }

        return volumes
    }

    func parseWMICVolumes(
        _ output: String,
        metadataByMountPoint: [String: VolumeCollectionMetadata] = [:]
    ) -> [VolumeInfo] {
        let entries = parseWMICEntries(output)
        return entries.compactMap { entry in
            guard
                let caption = entry["Caption"],
                let free = UInt64(entry["FreeSpace"] ?? ""),
                let total = UInt64(entry["Size"] ?? "")
            else {
                return nil
            }

            if total < 100 * 1024 * 1024 {
                return nil
            }

            let mountPoint = normalizedWindowsMountPoint(caption)
            let metadata = metadataByMountPoint[mountPoint]
            let fileSystem = metadata?.fileSystem ?? entry["FileSystem"] ?? ""
            let stableIdentifier = metadata?.stableIdentifier ?? entry["VolumeSerialNumber"]
            return VolumeInfo(
                platform: .windows,
                mountPoint: mountPoint,
                source: mountPoint,
                fileSystem: fileSystem,
                stableIdentifier: stableIdentifier,
                used: total >= free ? total - free : 0,
                total: total
            )
        }
    }

    func parseWindowsVolumeMetadata(_ output: String) -> [String: VolumeCollectionMetadata] {
        var metadata: [String: VolumeCollectionMetadata] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "|")
            guard fields.count >= 3 else { continue }

            let mountPoint = normalizedWindowsMountPoint(fields[0])
            guard mountPoint.count >= 3 else { continue }
            let fileSystem = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = fields[2...]
                .joined(separator: "|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            metadata[mountPoint] = VolumeCollectionMetadata(
                stableIdentifier: identifier.isEmpty ? nil : identifier,
                fileSystem: fileSystem
            )
        }
        return metadata
    }

    private func normalizedWindowsMountPoint(_ rawValue: String) -> String {
        var drive = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "\\")
            .uppercased()
        while drive.hasSuffix("\\") {
            drive.removeLast()
        }
        if !drive.hasSuffix(":") {
            drive += ":"
        }
        return "\(drive)\\"
    }

    func parseWMICProcesses(
        _ output: String,
        memoryTotal: UInt64,
        logicalProcessorCount: Int = 1
    ) -> [ProcessInfo] {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { return [] }

        var processes: [ProcessInfo] = []
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 5 else { continue }

            let pid = Int(fields[1]) ?? 0
            let name = fields[2]
            if pid <= 0 || name.isEmpty || name == "_Total" || name == "Idle" {
                continue
            }

            let rawCPU = parseWindowsDouble(fields[3]) ?? 0
            let workingSet = UInt64(fields[4]) ?? 0
            let cpuPercent = min(max(rawCPU / Double(max(logicalProcessorCount, 1)), 0), 100)
            let memoryPercent = memoryTotal > 0 ? (Double(workingSet) / Double(memoryTotal) * 100) : 0

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpuPercent,
                memoryPercent: memoryPercent,
                memoryBytes: workingSet
            ))
        }

        return processes
            .sorted { lhs, rhs in
                if lhs.cpuPercent == rhs.cpuPercent {
                    return lhs.memoryPercent > rhs.memoryPercent
                }
                return lhs.cpuPercent > rhs.cpuPercent
            }
            .map { $0 }
    }

    func parseWindowsGPUs(_ output: String) -> [GPUDevice] {
        var devices: [GPUDevice] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 1 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let vendor = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let driver = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let pnpDeviceID = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let status = parts.count > 5 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let lower = "\(name) \(vendor)".lowercased()
            let kind: GPUKind
            if lower.contains("nvidia") {
                kind = .nvidia
            } else if lower.contains("amd") || lower.contains("radeon") || lower.contains("advanced micro devices") {
                kind = .amd
            } else if lower.contains("intel") {
                kind = .intel
            } else {
                kind = .unknown
            }
            guard isPhysicalWindowsGPU(name: name, vendor: vendor, pnpDeviceID: pnpDeviceID, status: status, kind: kind) else {
                continue
            }
            let rawMemory = parts.count > 2 ? (UInt64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
            let memory = normalizedWindowsAdapterRAM(rawMemory, kind: kind)

            devices.append(GPUDevice(
                id: "windows-phys-\(devices.count)",
                name: name,
                vendor: vendor,
                kind: kind,
                driverVersion: driver,
                memoryTotal: memory,
                source: .wmi
            ))
        }

        return devices
    }

    func parseWindowsNvidiaGPUs(_ output: String) -> [GPUDevice] {
        parseCSVRows(output).compactMap { fields in
            guard fields.count >= 9 else { return nil }
            let index = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !index.isEmpty, !name.isEmpty else { return nil }
            let memoryTotalMB = UInt64(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return GPUDevice(
                id: "nvidia-\(index)",
                name: name,
                vendor: "NVIDIA",
                kind: .nvidia,
                driverVersion: fields[8].trimmingCharacters(in: .whitespacesAndNewlines),
                memoryTotal: memoryTotalMB * 1_048_576,
                source: .nvidiaSMI
            )
        }
    }

    func parseWindowsNvidiaSamples(_ output: String, timestamp: Date) -> [GPUSample] {
        parseCSVRows(output).compactMap { fields in
            guard fields.count >= 9 else { return nil }
            let index = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !index.isEmpty else { return nil }
            let utilization = parseWindowsDouble(fields[3])
            let memoryUsedMB = UInt64(fields[4].trimmingCharacters(in: .whitespacesAndNewlines))
            let memoryTotalMB = UInt64(fields[5].trimmingCharacters(in: .whitespacesAndNewlines))
            let temperature = parseWindowsDouble(fields[6])
            let power = parseWindowsDouble(fields[7])

            return GPUSample(
                deviceID: "nvidia-\(index)",
                utilizationPercent: utilization.map { min(max($0, 0), 100) },
                memoryUsed: memoryUsedMB.map { $0 * 1_048_576 },
                memoryTotal: memoryTotalMB.map { $0 * 1_048_576 },
                temperatureCelsius: temperature,
                powerWatts: power,
                processes: [],
                source: .nvidiaSMI,
                timestamp: timestamp
            )
        }
    }

    func parseWindowsGPUCounterSamples(_ output: String, timestamp: Date) -> [GPUSample] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 5, parts[0] == "PERF" else { return nil }

            let deviceID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let utilization = parseWindowsDouble(parts[2])
            let memoryUsed = UInt64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines))
            let rawMemoryTotal = UInt64(parts[4].trimmingCharacters(in: .whitespacesAndNewlines))
            let memoryTotal = rawMemoryTotal.flatMap { $0 > 0 ? $0 : nil }
            guard utilization != nil || memoryUsed != nil || memoryTotal != nil else { return nil }

            return GPUSample(
                deviceID: deviceID,
                utilizationPercent: utilization.map { min(max($0, 0), 100) },
                memoryUsed: memoryUsed,
                memoryTotal: memoryTotal,
                temperatureCelsius: nil,
                powerWatts: nil,
                processes: [],
                source: .wmi,
                timestamp: timestamp
            )
        }
    }

    func parseWindowsCPUUsage(_ output: String) -> WindowsCPUUsage {
        var usage = 0.0
        var user = 0.0
        var system = 0.0
        var samples: [CPUCoreSample] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|")

            if parts.count >= 4, parts[0] == "TOTAL" {
                usage = parseWindowsDouble(parts[1]) ?? 0
                user = parseWindowsDouble(parts[2]) ?? 0
                system = parseWindowsDouble(parts[3]) ?? 0
                continue
            }

            guard parts.count >= 5, parts[0] == "CORE" else { continue }
            let identifier = parts[1]
            let coreUsage = min(max(parseWindowsDouble(parts[2]) ?? 0, 0), 100)
            let coreUser = min(max(parseWindowsDouble(parts[3]) ?? 0, 0), 100)
            let coreSystem = min(max(parseWindowsDouble(parts[4]) ?? 0, 0), 100)
            let displayIndex = (Int(identifier) ?? samples.count) + 1
            samples.append(CPUCoreSample(
                identifier: "cpu\(identifier)",
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: coreUsage,
                userPercent: coreUser,
                systemPercent: coreSystem,
                iowaitPercent: 0,
                stealPercent: 0,
                idlePercent: max(100 - coreUsage, 0)
            ))
        }

        samples.sort { lhs, rhs in
            numericSuffix(lhs.identifier) < numericSuffix(rhs.identifier)
        }

        return WindowsCPUUsage(
            usagePercent: min(max(usage, 0), 100),
            userPercent: min(max(user, 0), 100),
            systemPercent: min(max(system, 0), 100),
            coreSamples: samples
        )
    }

    func parseWMICKeyValueOutput(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }

            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key, default: []].append(value)
        }
        return result
    }

    private func parseWMICEntries(_ output: String) -> [[String: String]] {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        let sections = normalized.components(separatedBy: "\n\n")
        return sections.compactMap { section in
            var entry: [String: String] = [:]
            for rawLine in section.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                if !key.isEmpty, !value.isEmpty {
                    entry[key] = value
                }
            }
            return entry.isEmpty ? nil : entry
        }
    }

    private func parseWindowsDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(trimmed) {
            return parsed
        }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    func parseTypeperfValue(_ output: String) -> Double? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return nil }
        let fields = parseCSVLine(lastLine)
        guard let rawValue = fields.last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else {
            return nil
        }
        return parseWindowsDouble(rawValue)
    }

    func parseNetstatInterfaceStats(_ output: String) -> (rx: UInt64, tx: UInt64) {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("bytes") else { continue }

            let parts = trimmed
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }

            let rx = UInt64(parts[1]) ?? 0
            let tx = UInt64(parts[2]) ?? 0
            return (rx, tx)
        }
        return (0, 0)
    }

    private func parseCSVLine(_ line: String) -> [String] {
        guard !line.isEmpty else { return [] }

        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "\"":
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            fields.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(character)
            }
        }

        fields.append(current)
        return fields
    }

    private func parseCSVRows(_ output: String) -> [[String]] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return parseCSVLine(trimmed).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func isPhysicalWindowsGPU(
        name: String,
        vendor: String,
        pnpDeviceID: String,
        status: String,
        kind: GPUKind
    ) -> Bool {
        if !status.isEmpty, status.caseInsensitiveCompare("OK") != .orderedSame {
            return false
        }

        let haystack = "\(name) \(vendor) \(pnpDeviceID)".lowercased()
        let virtualMarkers = [
            "virtual",
            "remote display",
            "indirect display",
            "mirage",
            "mirror driver",
            "microsoft basic render",
            "microsoft basic display",
            "vmware",
            "virtualbox",
            "hyper-v",
            "parallels",
            "citrix",
            "spice",
            "qxl",
            "sudomaker",
            "gameviewer"
        ]
        if virtualMarkers.contains(where: { haystack.contains($0) }) {
            return false
        }

        if kind != .unknown {
            return true
        }

        return haystack.contains("pci\\ven_")
    }

    private func normalizedWindowsAdapterRAM(_ rawValue: UInt64, kind: GPUKind) -> UInt64 {
        guard rawValue > 0 else { return 0 }

        // Win32_VideoController.AdapterRAM is commonly capped/truncated around
        // 4 GB for modern discrete GPUs. Prefer live NVIDIA/perf samples for
        // real VRAM and avoid surfacing a precise but wrong profile value.
        if (kind == .nvidia || kind == .amd) && rawValue >= 3_750_000_000 {
            return 0
        }

        return rawValue
    }

    private func numericSuffix(_ identifier: String) -> Int {
        let digits = identifier.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? Int.max
    }

    func parseWMIDate(_ raw: String) -> Date? {
        guard raw.count >= 21 else { return nil }

        let year = Int(raw.prefix(4)) ?? 0
        let month = Int(raw.dropFirst(4).prefix(2)) ?? 1
        let day = Int(raw.dropFirst(6).prefix(2)) ?? 1
        let hour = Int(raw.dropFirst(8).prefix(2)) ?? 0
        let minute = Int(raw.dropFirst(10).prefix(2)) ?? 0
        let second = Int(raw.dropFirst(12).prefix(2)) ?? 0

        let signIndex = raw.index(raw.startIndex, offsetBy: 21)
        guard signIndex < raw.endIndex else { return nil }
        let signCharacter = raw[signIndex]
        let offsetDigits = String(raw.dropFirst(22).prefix(3))
        let offsetMinutes = Int(offsetDigits) ?? 0
        let signedOffset = signCharacter == "-" ? -offsetMinutes : offsetMinutes

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: signedOffset * 60)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    func section(_ sections: [String], _ index: Int) -> String {
        guard sections.indices.contains(index) else { return "" }
        return sections[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
nonisolated struct WindowsCPUUsage: Sendable {
    let usagePercent: Double
    let userPercent: Double
    let systemPercent: Double
    let coreSamples: [CPUCoreSample]
}

nonisolated struct WindowsPeriodicStatsSnapshot: Sendable {
    let memory: (total: UInt64, used: UInt64, free: UInt64)?
    let uptime: TimeInterval?
    let processCount: Int?
    let network: (rx: UInt64, tx: UInt64)?
}
