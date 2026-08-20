import Foundation

nonisolated extension DarwinStatsCollector {
    // MARK: - Parsers

    func parseProcessorLoadOutput(
        _ output: String,
        previousValues: [String: LinuxCpuValues]
    ) -> (samples: [CPUCoreSample], newValues: [String: LinuxCpuValues]) {
        var samples: [CPUCoreSample] = []
        var newValues: [String: LinuxCpuValues] = [:]

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5,
                  let index = Int(parts[0]) else {
                continue
            }

            let identifier = "cpu\(index)"
            let values = LinuxCpuValues(
                user: UInt64(parts[1]) ?? 0,
                nice: UInt64(parts[4]) ?? 0,
                system: UInt64(parts[2]) ?? 0,
                idle: UInt64(parts[3]) ?? 0,
                iowait: 0,
                irq: 0,
                softirq: 0,
                steal: 0
            )
            let sample = makeCPUCoreSample(
                identifier: identifier,
                displayIndex: index + 1,
                current: values,
                previous: previousValues[identifier]
            )
            samples.append(sample)
            newValues[identifier] = values
        }

        samples.sort { lhs, rhs in
            numericCPUIndex(lhs.identifier) < numericCPUIndex(rhs.identifier)
        }

        return (samples, newValues)
    }

    private func makeCPUCoreSample(
        identifier: String,
        displayIndex: Int,
        current: LinuxCpuValues,
        previous: LinuxCpuValues?
    ) -> CPUCoreSample {
        guard let previous else {
            return CPUCoreSample(
                identifier: identifier,
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: 0,
                userPercent: 0,
                systemPercent: 0,
                iowaitPercent: 0,
                stealPercent: 0,
                idlePercent: 100
            )
        }

        let user = Double(clampedSubtract(current.user, previous.user) + clampedSubtract(current.nice, previous.nice))
        let system = Double(clampedSubtract(current.system, previous.system))
        let idle = Double(clampedSubtract(current.idle, previous.idle))
        let total = user + system + idle
        guard total > 0 else {
            return CPUCoreSample(
                identifier: identifier,
                displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
                usagePercent: 0,
                userPercent: 0,
                systemPercent: 0,
                iowaitPercent: 0,
                stealPercent: 0,
                idlePercent: 100
            )
        }

        let userPercent = user / total * 100
        let systemPercent = system / total * 100
        let idlePercent = idle / total * 100
        return CPUCoreSample(
            identifier: identifier,
            displayName: String(format: String(localized: "CPU %lld"), Int64(displayIndex)),
            usagePercent: userPercent + systemPercent,
            userPercent: userPercent,
            systemPercent: systemPercent,
            iowaitPercent: 0,
            stealPercent: 0,
            idlePercent: idlePercent
        )
    }

    private func numericCPUIndex(_ identifier: String) -> Int {
        Int(identifier.dropFirst(3)) ?? Int.max
    }

    private func clampedSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }

    func parseBootTime(_ output: String) -> TimeInterval {
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

    func parseVmStat(_ output: String, totalMemory: UInt64) -> (total: UInt64, used: UInt64, free: UInt64, cached: UInt64) {
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

    func parseNetstat(_ output: String) -> (rx: UInt64, tx: UInt64) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes
            guard parts.count >= 10 else { continue }

            let iface = parts[0]
            let network = parts[2]
            guard network.hasPrefix("<Link#"), shouldIncludeNetworkInterface(iface) else { continue }

            if let ibytes = UInt64(parts[6]), let obytes = UInt64(parts[9]) {
                totalRx += ibytes
                totalTx += obytes
            }
        }

        return (totalRx, totalTx)
    }

    private func shouldIncludeNetworkInterface(_ iface: String) -> Bool {
        let excludedPrefixes = [
            "lo", "gif", "stf", "awdl", "llw", "utun", "bridge", "p2p", "ap", "anpi"
        ]
        return !excludedPrefixes.contains { iface.hasPrefix($0) }
    }

    func parsePs(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []

        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let processLines: ArraySlice<String>
        if lines.first?.lowercased().hasPrefix("pid ") == true {
            processLines = lines.dropFirst()
        } else {
            processLines = lines[...]
        }

        for line in processLines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5 else { continue }

            let pid = Int(parts[0]) ?? 0
            let user = parts[1]
            let cpu = Double(parts[2]) ?? 0
            let mem = Double(parts[3]) ?? 0
            let name = parts[4]
            let command = parts.count > 5 ? parts.dropFirst(5).joined(separator: " ") : name

            guard pid > 0 else { continue }
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

    func parseTopCpu(_ output: String) -> (user: Double, system: Double, idle: Double) {
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

    func parseDf(
        _ output: String,
        metadataBySource: [String: VolumeCollectionMetadata] = [:]
    ) -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []

        var rawVolumes: [VolumeInfo] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted
            guard parts.count >= 9 else { continue }

            let totalMB = UInt64(parts[1]) ?? 0
            let usedMB = UInt64(parts[2]) ?? 0
            let source = parts[0]
            let mountPoint = parts[8...].joined(separator: " ")
            let metadata = metadataBySource[source]

            if totalMB < 100 { continue }

            guard let total = bytesFromMiB(totalMB),
                  let used = bytesFromMiB(usedMB) else { continue }

            rawVolumes.append(VolumeInfo(
                platform: .darwin,
                mountPoint: mountPoint,
                source: source,
                fileSystem: metadata?.fileSystem ?? "",
                stableIdentifier: metadata?.stableIdentifier,
                used: used,
                total: total
            ))
        }

        if let dataVolume = rawVolumes.first(where: { $0.mountPoint == "/System/Volumes/Data" }) {
            volumes.append(VolumeInfo(
                platform: .darwin,
                mountPoint: "/",
                source: dataVolume.source,
                fileSystem: dataVolume.fileSystem,
                stableIdentifier: dataVolume.stableIdentifier,
                kind: dataVolume.kind,
                used: dataVolume.used,
                total: dataVolume.total
            ))
        } else if let rootVolume = rawVolumes.first(where: { $0.mountPoint == "/" }) {
            volumes.append(rootVolume)
        }

        volumes.append(contentsOf: rawVolumes.filter { volume in
            volume.mountPoint.hasPrefix("/Volumes/")
        })

        if volumes.isEmpty {
            return rawVolumes.filter { !isDarwinSystemVolume($0.mountPoint) }
        }

        return volumes
    }

    func parseDiskutilVolumeMetadata(_ output: String) -> [String: VolumeCollectionMetadata] {
        guard let data = output.data(using: .utf8),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return [:]
        }

        var metadata: [String: VolumeCollectionMetadata] = [:]
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let deviceIdentifier = dictionary["DeviceIdentifier"] as? String {
                    let stableIdentifier = ["VolumeUUID", "APFSVolumeUUID", "APFSVolumeGroupID", "DiskUUID"]
                        .compactMap { dictionary[$0] as? String }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }
                    let fileSystem = (dictionary["FilesystemType"] as? String)
                        ?? (dictionary["Content"] as? String)
                        ?? ""
                    metadata["/dev/\(deviceIdentifier)"] = VolumeCollectionMetadata(
                        stableIdentifier: stableIdentifier,
                        fileSystem: fileSystem
                    )
                }

                for nested in dictionary.values {
                    visit(nested)
                }
            } else if let array = value as? [Any] {
                for nested in array {
                    visit(nested)
                }
            }
        }

        visit(propertyList)
        return metadata
    }

    func dfSources(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            guard let source = line.components(separatedBy: .whitespaces)
                .first(where: { !$0.isEmpty }),
                  seen.insert(source).inserted else { return nil }
            return source
        }
    }

    func isSafeDarwinDevicePath(_ source: String) -> Bool {
        source.range(of: #"^/dev/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private func bytesFromMiB(_ value: UInt64) -> UInt64? {
        let result = value.multipliedReportingOverflow(by: 1_048_576)
        return result.overflow ? nil : result.partialValue
    }

    private func isDarwinSystemVolume(_ mountPoint: String) -> Bool {
        mountPoint.hasPrefix("/System/Volumes/")
    }

    func section(_ sections: [String], _ index: Int) -> String {
        guard sections.indices.contains(index) else { return "" }
        return sections[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseDisplayProfile(_ output: String) -> [GPUDevice] {
        var devices: [GPUDevice] = []
        var currentName: String?
        var currentVendor = ""
        var currentVRAM: UInt64 = 0
        var inDisplaySection = false

        func flush() {
            guard let currentName, !currentName.isEmpty else { return }
            let lowerName = currentName.lowercased()
            let lowerVendor = currentVendor.lowercased()
            let kind: GPUKind
            if lowerName.contains("apple") || lowerVendor.contains("apple") {
                kind = .apple
            } else if lowerName.contains("amd") || lowerVendor.contains("amd") {
                kind = .amd
            } else if lowerName.contains("intel") || lowerVendor.contains("intel") {
                kind = .intel
            } else if lowerName.contains("nvidia") || lowerVendor.contains("nvidia") {
                kind = .nvidia
            } else {
                kind = .unknown
            }

            devices.append(GPUDevice(
                id: "display-\(devices.count)",
                name: currentName,
                vendor: currentVendor,
                kind: kind,
                driverVersion: "",
                memoryTotal: currentVRAM,
                source: .systemProfiler
            ))
        }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let leadingSpaces = line.prefix { $0 == " " }.count

            if trimmed == "Displays:" {
                inDisplaySection = true
                continue
            }

            if trimmed.hasSuffix(":"),
               !trimmed.contains("Graphics/Displays:"),
               !trimmed.contains("Displays:"),
               !trimmed.contains("Display:"),
               !trimmed.contains("Resolution:") {
                if inDisplaySection, leadingSpaces > 4 {
                    continue
                }
                inDisplaySection = false
                flush()
                currentName = String(trimmed.dropLast())
                currentVendor = ""
                currentVRAM = 0
            } else if trimmed.hasPrefix("Chipset Model:") {
                if currentName == nil {
                    currentName = valueAfterColon(trimmed)
                }
            } else if trimmed.hasPrefix("Vendor:") {
                currentVendor = valueAfterColon(trimmed)
            } else if trimmed.hasPrefix("VRAM") {
                currentVRAM = parseDarwinMemory(valueAfterColon(trimmed))
            }
        }

        flush()
        return devices
    }

    func parseDisplayProfileJSON(_ output: String) -> [GPUDevice] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPDisplaysDataType"] as? [[String: Any]] else {
            return []
        }

        return entries.enumerated().compactMap { index, entry in
            let model = stringValue(entry["sppci_model"])
                ?? stringValue(entry["_name"])
                ?? stringValue(entry["spdisplays_device-id"])
                ?? ""
            guard !model.isEmpty else { return nil }
            let vendor = normalizeDarwinVendor(stringValue(entry["spdisplays_vendor"]) ?? "")
            let lowerModel = model.lowercased()
            let lowerVendor = vendor.lowercased()
            let kind: GPUKind
            if lowerModel.contains("apple") || lowerVendor.contains("apple") {
                kind = .apple
            } else if lowerModel.contains("amd") || lowerVendor.contains("amd") {
                kind = .amd
            } else if lowerModel.contains("intel") || lowerVendor.contains("intel") {
                kind = .intel
            } else if lowerModel.contains("nvidia") || lowerVendor.contains("nvidia") {
                kind = .nvidia
            } else {
                kind = .unknown
            }

            let memory = parseDarwinMemory(stringValue(entry["spdisplays_vram"]) ?? "")
            return GPUDevice(
                id: "display-\(index)",
                name: model,
                vendor: vendor,
                kind: kind,
                driverVersion: "",
                memoryTotal: memory,
                source: .systemProfiler
            )
        }
    }

    private func valueAfterColon(_ line: String) -> String {
        line.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDarwinMemory(_ rawValue: String) -> UInt64 {
        let lower = rawValue.lowercased()
        let numberString = lower.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numberString) else { return 0 }
        if lower.contains("tb") {
            return UInt64(value * 1_099_511_627_776)
        }
        if lower.contains("gb") {
            return UInt64(value * 1_073_741_824)
        }
        if lower.contains("mb") {
            return UInt64(value * 1_048_576)
        }
        return 0
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func normalizeDarwinVendor(_ vendor: String) -> String {
        vendor
            .replacingOccurrences(of: "sppci_vendor_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
