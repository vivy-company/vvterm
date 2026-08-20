import Foundation

nonisolated extension DockerStatsCollector {
    func parseContainers(psOutput: String, statsOutput: String, timestamp: Date = Date()) -> DockerStats {
        let psRows = parseJSONLines(psOutput, as: DockerPSRow.self)
        let statsRows = parseJSONLines(statsOutput, as: DockerStatsRow.self)
        let statsByKey = makeStatsLookup(statsRows)

        var seenPSKeys = Set<String>()
        var containers: [DockerContainer] = []
        for row in psRows {
            let keys = containerKeys(for: row)
            guard keys.allSatisfy({ !seenPSKeys.contains($0) }) else { continue }
            seenPSKeys.formUnion(keys)
            containers.append(makeContainer(row: row, stats: stats(for: row, in: statsByKey)))
        }

        var existingKeys = Set(containers.flatMap { container in
            [
                container.id.lowercased(),
                container.shortID.lowercased(),
                container.name.lowercased()
            ]
        })

        for row in statsRows {
            let candidateKeys = [row.container, row.id, row.name]
                .compactMap { $0?.trimmedNonEmpty?.lowercased() }
            guard candidateKeys.allSatisfy({ !existingKeys.contains($0) }) else { continue }
            let container = makeContainer(stats: row)
            containers.append(container)
            existingKeys.formUnion(candidateKeys)
            existingKeys.insert(container.id.lowercased())
            existingKeys.insert(container.shortID.lowercased())
            existingKeys.insert(container.name.lowercased())
        }

        return DockerStats(
            availability: .available,
            containers: containers.sorted { lhs, rhs in
                if lhs.isRunning == rhs.isRunning {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.isRunning && !rhs.isRunning
            },
            timestamp: timestamp
        )
    }

    func parseSize(_ rawValue: String) -> UInt64? {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }

        let numberPrefix = cleaned.prefix { character in
            character.isNumber || character == "."
        }
        guard let value = Double(numberPrefix), value.isFinite else { return nil }

        let unit = cleaned.dropFirst(numberPrefix.count).lowercased()
        let multiplier: Double
        switch unit {
        case "b", "byte", "bytes", "":
            multiplier = 1
        case "kb":
            multiplier = 1_000
        case "kib", "k":
            multiplier = 1_024
        case "mb":
            multiplier = 1_000_000
        case "mib", "m":
            multiplier = 1_048_576
        case "gb":
            multiplier = 1_000_000_000
        case "gib", "g":
            multiplier = 1_073_741_824
        case "tb":
            multiplier = 1_000_000_000_000
        case "tib", "t":
            multiplier = 1_099_511_627_776
        default:
            return nil
        }

        let byteCount = value * multiplier
        let uint64UpperBound = 18_446_744_073_709_551_616.0
        guard byteCount.isFinite,
              byteCount >= 0,
              byteCount < uint64UpperBound else {
            return nil
        }
        return UInt64(byteCount)
    }

    private func containerKeys(for row: DockerPSRow) -> Set<String> {
        Set([
            row.id,
            row.id.map { String($0.prefix(12)) },
            row.names
        ].compactMap { $0?.trimmedNonEmpty?.lowercased() })
    }

    private func parseJSONLines<T: Decodable>(_ output: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        return output
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
                return try? decoder.decode(T.self, from: Data(trimmed.utf8))
            }
    }

    private func makeStatsLookup(_ rows: [DockerStatsRow]) -> [String: DockerStatsRow] {
        var result: [String: DockerStatsRow] = [:]
        for row in rows {
            for key in [row.container, row.id, row.name] {
                if let key = key?.trimmedNonEmpty?.lowercased() {
                    result[key] = row
                }
            }
        }
        return result
    }

    private func stats(for row: DockerPSRow, in lookup: [String: DockerStatsRow]) -> DockerStatsRow? {
        let keys = [
            row.id,
            row.id.map { String($0.prefix(12)) },
            row.names
        ]

        for key in keys.compactMap({ $0?.trimmedNonEmpty?.lowercased() }) {
            if let stats = lookup[key] {
                return stats
            }
        }

        return nil
    }

    private func makeContainer(row: DockerPSRow, stats: DockerStatsRow?) -> DockerContainer {
        let memory = parsePair(stats?.memoryUsage)
        let network = parsePair(stats?.networkIO)
        let block = parsePair(stats?.blockIO)

        return DockerContainer(
            id: row.id?.trimmedNonEmpty ?? stats?.container?.trimmedNonEmpty ?? UUID().uuidString,
            name: normalizedName(row.names ?? stats?.name ?? ""),
            image: row.image?.trimmedNonEmpty ?? "",
            command: row.command?.trimmedNonEmpty ?? "",
            state: DockerContainerState(rawState: row.state ?? ""),
            status: row.status?.trimmedNonEmpty ?? "",
            health: DockerHealthStatus(statusText: row.status ?? ""),
            createdAt: row.createdAt?.trimmedNonEmpty ?? "",
            runningFor: row.runningFor?.trimmedNonEmpty ?? "",
            ports: row.ports?.trimmedNonEmpty ?? "",
            cpuPercent: parsePercent(stats?.cpuPercent) ?? 0,
            memoryPercent: parsePercent(stats?.memoryPercent) ?? 0,
            memoryUsed: memory?.0,
            memoryLimit: memory?.1,
            networkRx: network?.0,
            networkTx: network?.1,
            blockRead: block?.0,
            blockWrite: block?.1,
            pids: Int(stats?.pids?.trimmedNonEmpty ?? "")
        )
    }

    private func makeContainer(stats row: DockerStatsRow) -> DockerContainer {
        let memory = parsePair(row.memoryUsage)
        let network = parsePair(row.networkIO)
        let block = parsePair(row.blockIO)
        let id = row.container?.trimmedNonEmpty ?? row.id?.trimmedNonEmpty ?? UUID().uuidString

        return DockerContainer(
            id: id,
            name: normalizedName(row.name ?? id),
            image: "",
            command: "",
            state: .running,
            status: String(localized: "Running"),
            health: .none,
            createdAt: "",
            runningFor: "",
            ports: "",
            cpuPercent: parsePercent(row.cpuPercent) ?? 0,
            memoryPercent: parsePercent(row.memoryPercent) ?? 0,
            memoryUsed: memory?.0,
            memoryLimit: memory?.1,
            networkRx: network?.0,
            networkTx: network?.1,
            blockRead: block?.0,
            blockWrite: block?.1,
            pids: Int(row.pids?.trimmedNonEmpty ?? "")
        )
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private func parsePercent(_ value: String?) -> Double? {
        guard let value else { return nil }
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    private func parsePair(_ value: String?) -> (UInt64, UInt64)? {
        guard let value else { return nil }
        let parts = value.components(separatedBy: "/")
        guard parts.count >= 2,
              let first = parseSize(parts[0]),
              let second = parseSize(parts[1]) else {
            return nil
        }
        return (first, second)
    }
}

nonisolated private struct DockerPSRow: Decodable, Sendable {
    let id: String?
    let names: String?
    let image: String?
    let command: String?
    let createdAt: String?
    let runningFor: String?
    let ports: String?
    let status: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case command = "Command"
        case createdAt = "CreatedAt"
        case runningFor = "RunningFor"
        case ports = "Ports"
        case status = "Status"
        case state = "State"
    }
}

nonisolated private struct DockerStatsRow: Decodable, Sendable {
    let blockIO: String?
    let container: String?
    let cpuPercent: String?
    let id: String?
    let memoryPercent: String?
    let memoryUsage: String?
    let name: String?
    let networkIO: String?
    let pids: String?

    enum CodingKeys: String, CodingKey {
        case blockIO = "BlockIO"
        case container = "Container"
        case cpuPercent = "CPUPerc"
        case id = "ID"
        case memoryPercent = "MemPerc"
        case memoryUsage = "MemUsage"
        case name = "Name"
        case networkIO = "NetIO"
        case pids = "PIDs"
    }
}

nonisolated private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
