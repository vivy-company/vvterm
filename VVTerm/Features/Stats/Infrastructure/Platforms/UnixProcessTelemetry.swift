import Foundation

/// Shared Unix process telemetry with one cross-platform contract:
/// CPU is the share of total machine capacity during the latest interval and
/// memory is resident physical memory as bytes and a percentage of physical RAM.
nonisolated enum UnixProcessTelemetry {
    struct ProcessRow {
        let pid: Int
        let user: String
        let cumulativeCPUTime: TimeInterval
        let rawCPUPercent: Double
        let residentBytes: UInt64
        let name: String
        let command: String
    }

    struct Collection {
        let processes: [ProcessInfo]
        let totalCount: Int
    }

    static func collect(
        client: SSHClient,
        context: StatsCollectionContext,
        platform: RemotePlatform,
        logicalProcessorCount: Int,
        memoryTotal: UInt64,
        limit: Int?
    ) async throws -> Collection {
        let snapshotOutput = try await client.execute(
            RemoteTerminalBootstrap.wrapPOSIXShellCommand(cpuSnapshotCommand(platform: platform)),
            timeout: .seconds(8)
        )
        let cumulativeCPUTimeByPID = parseCPUSnapshot(snapshotOutput, platform: platform)
        let now = Date()
        let intervalCPUPercentages = context.processCPUPercentages(
            cumulativeCPUTimeByPID: cumulativeCPUTimeByPID,
            timestamp: now,
            logicalProcessorCount: logicalProcessorCount
        )

        let selectedPIDs: [Int]?
        if let limit, !intervalCPUPercentages.isEmpty {
            selectedPIDs = intervalCPUPercentages
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                .prefix(max(limit * 2, limit))
                .map(\.key)
        } else {
            selectedPIDs = nil
        }

        let detailsOutput = try await client.execute(
            RemoteTerminalBootstrap.wrapPOSIXShellCommand(processDetailsCommand(
                platform: platform,
                limit: selectedPIDs == nil ? limit : nil,
                pids: selectedPIDs
            )),
            timeout: .seconds(8)
        )
        let rows = parseProcessRows(detailsOutput)
        let processes = makeProcesses(
            from: rows,
            intervalCPUPercentages: intervalCPUPercentages,
            memoryTotal: memoryTotal
        )

        return Collection(
            processes: limit.map { Array(processes.prefix($0)) } ?? processes,
            totalCount: cumulativeCPUTimeByPID.count
        )
    }

    static func processDetailsCommand(
        platform: RemotePlatform,
        limit: Int?,
        pids: [Int]?
    ) -> String {
        let selection: String
        if let pids, !pids.isEmpty {
            selection = "-p \(pids.map(String.init).joined(separator: ","))"
        } else {
            selection = platform == .linux ? "-e" : "-A"
        }

        let base = "export LC_ALL=C LANG=C; ps \(selection) -o pid=,user=,time=,pcpu=,rss=,args= 2>/dev/null"
        guard let limit else { return base }

        if platform == .linux {
            return "\(base.replacingOccurrences(of: " 2>/dev/null", with: " --sort=-pcpu 2>/dev/null")) | head -n \(limit)"
        }
        return "\(base) | sort -k4 -nr | head -n \(limit)"
    }

    static func parseProcessRows(_ output: String) -> [ProcessRow] {
        output.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let fields = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard fields.count >= 6,
                  let pid = Int(fields[0]), pid > 0,
                  let cumulativeCPUTime = parseCPUTime(fields[2]),
                  let rawCPUPercent = Double(fields[3]),
                  let residentKiB = UInt64(fields[4]) else {
                return nil
            }

            let command = fields.dropFirst(5).joined(separator: " ")
            let executable = fields[5]
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let residentResult = residentKiB.multipliedReportingOverflow(by: 1_024)

            return ProcessRow(
                pid: pid,
                user: fields[1],
                cumulativeCPUTime: cumulativeCPUTime,
                rawCPUPercent: rawCPUPercent,
                residentBytes: residentResult.overflow ? UInt64.max : residentResult.partialValue,
                name: name.isEmpty ? executable : name,
                command: command
            )
        }
    }

    static func makeProcesses(
        from rows: [ProcessRow],
        intervalCPUPercentages: [Int: Double],
        memoryTotal: UInt64
    ) -> [ProcessInfo] {
        let processes = rows.map { row in
            // There is no truthful interval value until two cumulative samples exist.
            // Show zero for that first interval instead of mixing in ps's incompatible
            // lifetime/decaying-average %CPU definition.
            let cpuPercent = intervalCPUPercentages[row.pid] ?? 0
            let memoryPercent = memoryTotal > 0
                ? Double(row.residentBytes) / Double(memoryTotal) * 100
                : 0

            return ProcessInfo(
                pid: row.pid,
                name: row.name,
                cpuPercent: min(max(cpuPercent.isFinite ? cpuPercent : 0, 0), 100),
                memoryPercent: min(max(memoryPercent.isFinite ? memoryPercent : 0, 0), 100),
                memoryBytes: row.residentBytes,
                user: row.user,
                command: row.command
            )
        }

        // The first command is already remotely ordered by ps %CPU. Preserve that
        // useful candidate order while the interval baseline is being established.
        guard !intervalCPUPercentages.isEmpty else { return processes }
        return processes.sorted { lhs, rhs in
            if lhs.cpuPercent == rhs.cpuPercent {
                if lhs.memoryPercent == rhs.memoryPercent { return lhs.pid < rhs.pid }
                return lhs.memoryPercent > rhs.memoryPercent
            }
            return lhs.cpuPercent > rhs.cpuPercent
        }
    }

    static func parseCPUTime(_ value: String) -> TimeInterval? {
        let dayParts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let days: Double
        let clock: Substring
        if dayParts.count == 2 {
            guard let parsedDays = Double(dayParts[0]) else { return nil }
            days = parsedDays
            clock = dayParts[1]
        } else {
            days = 0
            clock = dayParts[0]
        }

        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard let seconds = parts.last.flatMap({ Double($0) }) else { return nil }
        let minutes = parts.count >= 2 ? (Double(parts[parts.count - 2]) ?? 0) : 0
        let hours = parts.count >= 3 ? (Double(parts[parts.count - 3]) ?? 0) : 0
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    private static func cpuSnapshotCommand(platform: RemotePlatform) -> String {
        if platform == .linux {
            return """
            LC_ALL=C LANG=C
            hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
            echo "__HZ__|$hz"
            for stat_file in /proc/[0-9]*/stat; do
                [ -r "$stat_file" ] || continue
                IFS= read -r stat_line < "$stat_file" || continue
                pid=${stat_line%% *}
                rest=${stat_line##*) }
                set -- $rest
                [ "$#" -ge 13 ] || continue
                user_ticks=${12}
                system_ticks=${13}
                case "$user_ticks" in ''|*[!0-9]*) continue ;; esac
                case "$system_ticks" in ''|*[!0-9]*) continue ;; esac
                echo "$pid|$((user_ticks + system_ticks))"
            done
            """
        }

        return "export LC_ALL=C LANG=C; ps -Axo pid=,time= 2>/dev/null"
    }

    private static func parseCPUSnapshot(_ output: String, platform: RemotePlatform) -> [Int: TimeInterval] {
        var tickRate = 1.0
        var result: [Int: TimeInterval] = [:]

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("__HZ__|") {
                tickRate = Double(line.dropFirst("__HZ__|".count)) ?? 100
                continue
            }

            if platform == .linux {
                let fields = line.split(separator: "|", maxSplits: 1)
                guard fields.count == 2,
                      let pid = Int(fields[0]),
                      let ticks = Double(fields[1]), tickRate > 0 else {
                    continue
                }
                result[pid] = ticks / tickRate
            } else {
                let fields = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard fields.count >= 2,
                      let pid = Int(fields[0]),
                      let cpuTime = parseCPUTime(fields[1]) else {
                    continue
                }
                result[pid] = cpuTime
            }
        }

        return result
    }
}
