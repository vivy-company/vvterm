import Foundation

nonisolated extension LinuxStatsCollector {
    // MARK: - Parsers

    func isProcStatValid(_ output: String) -> Bool {
        let firstLine = output.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("cpu ") } ?? output
        let components = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        return components.count >= 8 && components.first == "cpu"
    }

    func isProcMeminfoValid(_ output: String) -> Bool {
        output.contains("MemTotal:")
    }

    func isProcNetDevValid(_ output: String) -> Bool {
        output.contains(":") && output.contains("bytes")
    }

    func parseProcStat(_ output: String, prevValues: LinuxCpuValues?) -> (result: CpuResult, newValues: LinuxCpuValues) {
        let firstLine = output.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("cpu ") } ?? output
        guard let current = parseCpuValues(firstLine) else {
            let zeroValues = LinuxCpuValues(user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0)
            return (CpuResult(total: 0, user: 0, system: 0, iowait: 0, steal: 0, idle: 100), zeroValues)
        }

        return (calculateCpuResult(current: current, previous: prevValues), current)
    }

    func parseProcStatCores(
        _ output: String,
        prevValues: [String: LinuxCpuValues]
    ) -> (samples: [CPUCoreSample], newValues: [String: LinuxCpuValues]) {
        var samples: [CPUCoreSample] = []
        var newValues: [String: LinuxCpuValues] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let identifier = parts.first,
                  identifier.hasPrefix("cpu"),
                  identifier != "cpu",
                  let values = parseCpuValues(trimmed) else {
                continue
            }

            let result = calculateCpuResult(current: values, previous: prevValues[identifier])
            let indexText = String(identifier.dropFirst(3))
            let displayIndex = (Int(indexText) ?? samples.count) + 1
            samples.append(CPUCoreSample(
                identifier: identifier,
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: result.total,
                userPercent: result.user,
                systemPercent: result.system,
                iowaitPercent: result.iowait,
                stealPercent: result.steal,
                idlePercent: result.idle
            ))
            newValues[identifier] = values
        }

        samples.sort { lhs, rhs in
            numericCPUIndex(lhs.identifier) < numericCPUIndex(rhs.identifier)
        }

        return (samples, newValues)
    }

    private func parseCpuValues(_ line: String) -> LinuxCpuValues? {
        let components = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard components.count >= 8 else {
            return nil
        }

        let user = UInt64(components[1]) ?? 0
        let nice = UInt64(components[2]) ?? 0
        let system = UInt64(components[3]) ?? 0
        let idle = UInt64(components[4]) ?? 0
        let iowait = UInt64(components[5]) ?? 0
        let irq = UInt64(components[6]) ?? 0
        let softirq = UInt64(components[7]) ?? 0
        let steal = components.count > 8 ? (UInt64(components[8]) ?? 0) : 0

        return LinuxCpuValues(
            user: user, nice: nice, system: system, idle: idle,
            iowait: iowait, irq: irq, softirq: softirq, steal: steal
        )
    }

    private func calculateCpuResult(current: LinuxCpuValues, previous: LinuxCpuValues?) -> CpuResult {
        if let prev = previous {
            let dUser = Double(clampedAdd(clampedSubtract(current.user, prev.user), clampedSubtract(current.nice, prev.nice)))
            let dSystem = Double(
                clampedAdd(
                    clampedAdd(clampedSubtract(current.system, prev.system), clampedSubtract(current.irq, prev.irq)),
                    clampedSubtract(current.softirq, prev.softirq)
                )
            )
            let dIdle = Double(clampedSubtract(current.idle, prev.idle))
            let dIowait = Double(clampedSubtract(current.iowait, prev.iowait))
            let dSteal = Double(clampedSubtract(current.steal, prev.steal))

            let total = dUser + dSystem + dIdle + dIowait + dSteal
            if total > 0 {
                return CpuResult(
                    total: (dUser + dSystem + dIowait + dSteal) / total * 100,
                    user: dUser / total * 100,
                    system: dSystem / total * 100,
                    iowait: dIowait / total * 100,
                    steal: dSteal / total * 100,
                    idle: dIdle / total * 100
                )
            }
        }

        return CpuResult(total: 0, user: 0, system: 0, iowait: 0, steal: 0, idle: 100)
    }

    private func numericCPUIndex(_ identifier: String) -> Int {
        Int(identifier.dropFirst(3)) ?? Int.max
    }

    func parseTopCpu(_ output: String) -> CpuResult? {
        let line = output.components(separatedBy: .newlines).first { line in
            line.lowercased().contains("cpu(s)") || line.lowercased().contains("%cpu")
        }
        guard let cpuLine = line else { return nil }

        func extract(_ token: String) -> Double? {
            let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*"# + token
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(cpuLine.startIndex..<cpuLine.endIndex, in: cpuLine)
            guard let match = regex.firstMatch(in: cpuLine, options: [], range: range),
                  let valueRange = Range(match.range(at: 1), in: cpuLine) else { return nil }
            return Double(cpuLine[valueRange])
        }

        let user = extract("us") ?? 0
        let system = extract("sy") ?? 0
        let idle = extract("id") ?? max(0, 100 - user - system)
        let iowait = extract("wa") ?? 0
        let steal = extract("st") ?? 0
        let total = max(0, min(100, user + system + iowait + steal))

        return CpuResult(total: total, user: user, system: system, iowait: iowait, steal: steal, idle: idle)
    }

    func parseCPUProfile(_ output: String) -> (model: String, vendor: String, cores: Int, threads: Int) {
        var model = ""
        var vendor = ""
        var cores = 0
        var threads = 0
        var coresPerSocket = 0
        var sockets = 0

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Model name:") {
                model = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("Vendor ID:") {
                vendor = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("CPU(s):"), threads == 0 {
                threads = Int(valueAfterColon(trimmed)) ?? 0
            } else if trimmed.hasPrefix("Core(s) per socket:") {
                coresPerSocket = Int(valueAfterColon(trimmed)) ?? 0
            } else if trimmed.hasPrefix("Socket(s):") {
                sockets = Int(valueAfterColon(trimmed)) ?? 0
            } else if trimmed.hasPrefix("model name"), model.isEmpty {
                model = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("vendor_id"), vendor.isEmpty {
                vendor = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("processor") {
                threads += 1
            }
        }

        if coresPerSocket > 0 && sockets > 0 {
            cores = coresPerSocket * sockets
        } else {
            cores = threads
        }

        return (model, vendor, max(cores, 0), max(threads, cores))
    }

    func parseMemTotal(_ output: String) -> UInt64 {
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2,
              let kib = UInt64(parts[1]) else {
            return 0
        }
        return bytesFromKiB(kib) ?? 0
    }

    func parseNvidiaProfile(_ output: String) -> [GPUDevice] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> GPUDevice? in
                let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 4,
                      !parts[0].isEmpty else {
                    return nil
                }

                let memoryMiB = UInt64(parts[3]) ?? 0
                return GPUDevice(
                    id: "nvidia-\(parts[0])",
                    name: parts[1],
                    vendor: "NVIDIA",
                    kind: .nvidia,
                    driverVersion: parts[2],
                    memoryTotal: multiplyBytes(memoryMiB, by: bytesPerMiB) ?? 0,
                    source: .nvidiaSMI
                )
            }
    }

    func parsePCIGPUs(_ output: String, existingIDs: Set<String>) -> [GPUDevice] {
        var devices: [GPUDevice] = []
        for (index, line) in output.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            let kind: GPUKind
            let vendor: String
            if lower.contains("nvidia") {
                kind = .nvidia
                vendor = "NVIDIA"
            } else if lower.contains("amd") || lower.contains("advanced micro devices") || lower.contains("ati") {
                kind = .amd
                vendor = "AMD"
            } else if lower.contains("intel") {
                kind = .intel
                vendor = "Intel"
            } else {
                kind = .unknown
                vendor = ""
            }

            if kind == .nvidia, existingIDs.contains(where: { $0.hasPrefix("nvidia-") }) {
                continue
            }

            let id = "pci-\(index)"
            guard !existingIDs.contains(id) else { continue }
            devices.append(GPUDevice(
                id: id,
                name: parsePCIDeviceName(trimmed, vendor: vendor),
                vendor: vendor,
                kind: kind,
                driverVersion: "",
                memoryTotal: 0,
                source: .unknown
            ))
        }
        return devices
    }

    private func parsePCIDeviceName(_ line: String, vendor: String) -> String {
        let quotedParts = line.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if quotedParts.count >= 4 {
            return quotedParts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if quotedParts.count >= 2 {
            return quotedParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return vendor.isEmpty ? line : line.replacingOccurrences(of: vendor, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseNvidiaSamples(_ output: String, timestamp: Date) -> [GPUSample] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> GPUSample? in
                let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 6,
                      !parts[0].isEmpty else {
                    return nil
                }

                let memoryUsedMiB = UInt64(parts[2])
                let memoryTotalMiB = UInt64(parts[3])
                return GPUSample(
                    deviceID: "nvidia-\(parts[0])",
                    utilizationPercent: Double(parts[1]),
                    memoryUsed: memoryUsedMiB.flatMap { multiplyBytes($0, by: bytesPerMiB) },
                    memoryTotal: memoryTotalMiB.flatMap { multiplyBytes($0, by: bytesPerMiB) },
                    temperatureCelsius: Double(parts[4]),
                    powerWatts: parseOptionalDouble(parts[5]),
                    processes: [],
                    source: .nvidiaSMI,
                    timestamp: timestamp
                )
            }
    }

    private func parseOptionalDouble(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "[Not Supported]",
              trimmed != "N/A" else {
            return nil
        }
        return Double(trimmed)
    }

    private func valueAfterColon(_ line: String) -> String {
        line.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseProcMeminfo(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64) {
        var total: UInt64 = 0
        var free: UInt64 = 0
        var available: UInt64 = 0
        var buffers: UInt64 = 0
        var cached: UInt64 = 0
        var sReclaimable: UInt64 = 0
        var shmem: UInt64 = 0

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let valueStr = parts[1].components(separatedBy: .whitespaces).first ?? "0"
            let value = UInt64(valueStr) ?? 0

            switch parts[0] {
            case "MemTotal": total = bytesFromKiB(value) ?? 0
            case "MemFree": free = bytesFromKiB(value) ?? 0
            case "MemAvailable": available = bytesFromKiB(value) ?? 0
            case "Buffers": buffers = bytesFromKiB(value) ?? 0
            case "Cached": cached = bytesFromKiB(value) ?? 0
            case "SReclaimable": sReclaimable = bytesFromKiB(value) ?? 0
            case "Shmem": shmem = bytesFromKiB(value) ?? 0
            default: break
            }
        }

        let actualCached = clampedAdd(cached, sReclaimable)
        let used: UInt64
        if available > 0 {
            used = clampedSubtract(total, available)
        } else {
            // MemAvailable was added after the original /proc/meminfo fields and
            // can also be hidden by restricted proc mounts. Match free(1)'s
            // fallback instead of treating the whole machine as used.
            let reclaimable = clampedAdd(clampedAdd(free, buffers), actualCached)
            used = min(clampedAdd(clampedSubtract(total, reclaimable), shmem), total)
        }
        return (total, used, free, actualCached, buffers)
    }

    func parseFreeMemory(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64)? {
        let lines = output.components(separatedBy: .newlines)
        guard let memLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Mem:") }) else { return nil }
        let parts = memLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 4 else { return nil }

        let total = UInt64(parts[1]) ?? 0
        let used = UInt64(parts[2]) ?? 0
        let free = UInt64(parts[3]) ?? 0
        let cached = parts.count > 5 ? (UInt64(parts[5]) ?? 0) : 0

        return (total, used, free, cached, 0)
    }

    func parseTopMemory(_ output: String) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64, buffers: UInt64)? {
        let line = output.components(separatedBy: .newlines).first { line in
            line.lowercased().contains("mem") && line.contains("total")
        }
        guard let memLine = line else { return nil }

        func extract(_ token: String) -> Double? {
            let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*"# + token
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(memLine.startIndex..<memLine.endIndex, in: memLine)
            guard let match = regex.firstMatch(in: memLine, options: [], range: range),
                  let valueRange = Range(match.range(at: 1), in: memLine) else { return nil }
            return Double(memLine[valueRange])
        }

        let totalValue = extract("total") ?? 0
        let freeValue = extract("free") ?? 0
        let usedValue = extract("used") ?? 0
        let cachedValue = extract("buff/cache") ?? 0

        let unit: Double
        if memLine.lowercased().contains("gib") {
            unit = 1_073_741_824
        } else if memLine.lowercased().contains("mib") {
            unit = 1_048_576
        } else if memLine.lowercased().contains("kib") {
            unit = 1024
        } else {
            unit = 1_048_576
        }

        let total = UInt64(totalValue * unit)
        let free = UInt64(freeValue * unit)
        let used = UInt64(usedValue * unit)
        let cached = UInt64(cachedValue * unit)

        return (total, used, free, cached, 0)
    }

    func parseUptimeLoadAverage(_ output: String) -> (Double, Double, Double) {
        let lower = output.lowercased()
        if let range = lower.range(of: "load average:") {
            let suffix = output[range.upperBound...]
            let cleaned = String(suffix).replacingOccurrences(of: ",", with: " ")
            return StatsParsingUtils.parseLoadAverage(cleaned)
        }
        if let range = lower.range(of: "load averages:") {
            let suffix = output[range.upperBound...]
            let cleaned = String(suffix).replacingOccurrences(of: ",", with: " ")
            return StatsParsingUtils.parseLoadAverage(cleaned)
        }
        return (0, 0, 0)
    }

    func parseUptimeSeconds(_ output: String) -> TimeInterval {
        guard let range = output.lowercased().range(of: " up ") else { return 0 }
        let suffix = output[range.upperBound...]
        let parts = suffix.components(separatedBy: ",")

        var totalSeconds: TimeInterval = 0
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("day") {
                let dayValue = trimmed.components(separatedBy: .whitespaces).first ?? "0"
                totalSeconds += (Double(dayValue) ?? 0) * 86400
            } else if trimmed.contains("min") {
                let minValue = trimmed.components(separatedBy: .whitespaces).first ?? "0"
                totalSeconds += (Double(minValue) ?? 0) * 60
            } else if trimmed.contains(":") {
                let timeParts = trimmed.components(separatedBy: ":")
                if timeParts.count == 2 {
                    let hours = Double(timeParts[0].trimmingCharacters(in: .whitespaces)) ?? 0
                    let minutes = Double(timeParts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    totalSeconds += hours * 3600 + minutes * 60
                }
            }
        }

        return totalSeconds
    }

    func parseProcNetDev(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        for line in output.components(separatedBy: .newlines) {
            guard line.contains(":") && !line.contains("lo:") else { continue }

            let parts = line.components(separatedBy: ":").last?
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty } ?? []

            guard parts.count >= 9 else { continue }

            totalRx = clampedAdd(totalRx, UInt64(parts[0]) ?? 0)
            totalTx = clampedAdd(totalTx, UInt64(parts[8]) ?? 0)
        }

        return (totalRx, totalTx)
    }

    func parseSysClassNet(_ output: String) -> (rx: UInt64, tx: UInt64)? {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var found = false

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }
            let rx = UInt64(parts[1]) ?? 0
            let tx = UInt64(parts[2]) ?? 0
            totalRx = clampedAdd(totalRx, rx)
            totalTx = clampedAdd(totalTx, tx)
            found = true
        }

        return found ? (totalRx, totalTx) : nil
    }

    func parseIpLinkOrIfconfig(_ output: String) -> (rx: UInt64, tx: UInt64)? {
        let lines = output.components(separatedBy: .newlines)

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var currentIface: String?
        var expectRx = false
        var expectTx = false
        var found = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let ifaceMatch = trimmed.range(of: #"^\d+:\s*([^:]+):"#, options: .regularExpression) {
                let start = trimmed[ifaceMatch].split(separator: " ").dropFirst().first ?? ""
                currentIface = String(start).replacingOccurrences(of: ":", with: "")
                continue
            }

            if trimmed.hasPrefix("RX:") {
                expectRx = true
                continue
            }
            if trimmed.hasPrefix("TX:") {
                expectTx = true
                continue
            }

            if expectRx {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let iface = currentIface, iface != "lo", parts.count > 0, let rx = UInt64(parts[0]) {
                    totalRx = clampedAdd(totalRx, rx)
                    found = true
                }
                expectRx = false
                continue
            }

            if expectTx {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let iface = currentIface, iface != "lo", parts.count > 0, let tx = UInt64(parts[0]) {
                    totalTx = clampedAdd(totalTx, tx)
                    found = true
                }
                expectTx = false
                continue
            }
        }

        if found {
            return (totalRx, totalTx)
        }

        let rxRegex = try? NSRegularExpression(pattern: #"RX.*bytes\s+([0-9]+)"#, options: [.caseInsensitive])
        let txRegex = try? NSRegularExpression(pattern: #"TX.*bytes\s+([0-9]+)"#, options: [.caseInsensitive])

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = rxRegex?.firstMatch(in: line, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let rx = UInt64(line[valueRange]) {
                totalRx = clampedAdd(totalRx, rx)
                found = true
            }
            if let match = txRegex?.firstMatch(in: line, options: [], range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let tx = UInt64(line[valueRange]) {
                totalTx = clampedAdd(totalTx, tx)
                found = true
            }
        }

        return found ? (totalRx, totalTx) : nil
    }

    func parseDfVolumes(
        _ output: String,
        metadataBySource: [String: VolumeCollectionMetadata] = [:]
    ) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let defaultUnit = lines.first.flatMap(dfUnitMultiplier)
        let volumeLines = defaultUnit == nil ? lines : Array(lines.dropFirst())
        let headerFields = lines.first?
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty } ?? []
        let includesFileSystem = headerFields.contains { $0.caseInsensitiveCompare("Type") == .orderedSame }

        for line in volumeLines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let totalIndex = includesFileSystem ? 2 : 1
            let usedIndex = includesFileSystem ? 3 : 2
            let mountIndex = includesFileSystem ? 6 : 5
            guard parts.indices.contains(totalIndex),
                  parts.indices.contains(usedIndex),
                  parts.indices.contains(mountIndex) else { continue }

            let source = parts[0]
            let metadata = metadataBySource[source]
            let fileSystem = includesFileSystem ? parts[1] : (metadata?.fileSystem ?? "")
            let mountPoint = parts[mountIndex...].joined(separator: " ")
            guard
                let totalBytes = parseDfByteCount(parts[totalIndex], defaultUnit: defaultUnit),
                let usedBytes = parseDfByteCount(parts[usedIndex], defaultUnit: defaultUnit)
            else { continue }
            if totalBytes < 100 * bytesPerMiB { continue }

            volumes.append(VolumeInfo(
                platform: .linux,
                mountPoint: mountPoint,
                source: source,
                fileSystem: fileSystem,
                stableIdentifier: metadata?.stableIdentifier,
                used: usedBytes,
                total: totalBytes
            ))
        }

        return volumes
    }

    func parseLSBLKVolumeMetadata(_ output: String) -> [String: VolumeCollectionMetadata] {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["blockdevices"] as? [[String: Any]] else {
            return [:]
        }

        var metadata: [String: VolumeCollectionMetadata] = [:]
        func visit(_ device: [String: Any]) {
            if let source = device["name"] as? String {
                let stableIdentifier = (device["uuid"] as? String).flatMap { value in
                    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
                let fileSystem = (device["fstype"] as? String) ?? ""
                metadata[source] = VolumeCollectionMetadata(
                    stableIdentifier: stableIdentifier,
                    fileSystem: fileSystem
                )
            }

            for child in device["children"] as? [[String: Any]] ?? [] {
                visit(child)
            }
        }

        for device in devices {
            visit(device)
        }
        return metadata
    }

    func parsePs(_ output: String) -> [ProcessInfo] {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first else { return [] }

        if firstLine.lowercased().hasPrefix("user ") {
            return parseAuxProcesses(lines)
        }

        return parseProcessTable(lines)
    }

    private func parseProcessTable(_ lines: [String]) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in lines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5 else { continue }

            guard let pid = Int(parts[0]) else { continue }
            let user = parts[1]
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let name = parts[4]
            let command = parts.count > 5 ? parts.dropFirst(5).joined(separator: " ") : name

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpu,
                memoryPercent: mem,
                user: user,
                command: command
            ))
        }

        return processes
    }

    private func parseAuxProcesses(_ lines: [String]) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 11 else { continue }

            let pid = Int(parts[1]) ?? 0
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let user = parts[0]
            let name = parts[10]
            let command = parts.dropFirst(10).joined(separator: " ")

            processes.append(ProcessInfo(
                pid: pid,
                name: name,
                cpuPercent: cpu,
                memoryPercent: mem,
                user: user,
                command: command
            ))
        }

        return processes
    }

    private func clampedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private func clampedSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }

    private func bytesFromKiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerKiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromMiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerMiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromGiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerGiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromTiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerTiB)
        return result.overflow ? nil : result.partialValue
    }

    private func bytesFromPiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: bytesPerPiB)
        return result.overflow ? nil : result.partialValue
    }

    private func dfUnitMultiplier(_ header: String) -> UInt64? {
        let normalized = header.lowercased()
        if normalized.contains("1k-blocks") || normalized.contains("1024-blocks") {
            return bytesPerKiB
        }
        if normalized.contains("512-blocks") {
            return 512
        }
        if normalized.contains("1m-blocks") {
            return bytesPerMiB
        }
        if normalized.contains("1g-blocks") {
            return bytesPerGiB
        }
        return nil
    }

    private func parseDfByteCount(_ rawValue: String, defaultUnit: UInt64?) -> UInt64? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let numeric = UInt64(trimmed) {
            guard let defaultUnit else { return numeric }
            return multiplyBytes(numeric, by: defaultUnit)
        }

        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        let suffixPart = trimmed.dropFirst(numberPart.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !numberPart.isEmpty, let value = Double(numberPart), value.isFinite, value >= 0 else {
            return nil
        }

        let multiplier: Double
        switch suffixPart {
        case "K", "KB", "KI", "KIB":
            multiplier = Double(bytesPerKiB)
        case "M", "MB", "MI", "MIB":
            multiplier = Double(bytesPerMiB)
        case "G", "GB", "GI", "GIB":
            multiplier = Double(bytesPerGiB)
        case "T", "TB", "TI", "TIB":
            multiplier = Double(bytesPerTiB)
        case "P", "PB", "PI", "PIB":
            multiplier = Double(bytesPerPiB)
        case "B":
            multiplier = 1
        case "":
            guard let defaultUnit else { return nil }
            multiplier = Double(defaultUnit)
        default:
            return nil
        }

        let bytes = value * multiplier
        guard bytes.isFinite,
              let result = UInt64(exactly: bytes.rounded()) else { return nil }
        return result
    }

    private func multiplyBytes(_ value: UInt64, by multiplier: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? nil : result.partialValue
    }
}

// MARK: - CPU Result Helper

nonisolated struct CpuResult: Sendable {
    let total: Double
    let user: Double
    let system: Double
    let iowait: Double
    let steal: Double
    let idle: Double
}
