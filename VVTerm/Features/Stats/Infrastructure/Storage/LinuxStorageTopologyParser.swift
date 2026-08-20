import Foundation

nonisolated struct LinuxStorageMemberCandidate: Hashable, Sendable {
    let role: StorageHealthMemberRole
    let path: String?
    let findings: [StorageHealthFinding]
}

nonisolated struct LinuxStorageTopologyDiscovery: Hashable, Sendable {
    let kind: StorageTopologyKind
    let name: String?
    let findings: [StorageHealthFinding]
    let members: [LinuxStorageMemberCandidate]
}

/// Parses locale-stable, read-only BTRFS and ZFS command output. Raw paths are
/// transient infrastructure locators and never cross into the domain report.
nonisolated enum LinuxStorageTopologyParser {
    static let maximumMemberCount = 32

    static func parseBTRFS(filesystem output: String, deviceStats: String) -> LinuxStorageTopologyDiscovery? {
        let lines = output.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.localizedCaseInsensitiveContains("uuid:") }) else {
            return nil
        }

        let name = btrfsName(in: lines)
        let errorFindings = btrfsErrorFindings(deviceStats)
        var members: [LinuxStorageMemberCandidate] = []
        var sawMissingSummary = false

        for line in lines {
            if line.localizedCaseInsensitiveContains("some devices missing") {
                sawMissingSummary = true
            }
            guard line.range(of: #"\bdevid\s+\d+\b"#, options: .regularExpression) != nil,
                  let pathRange = line.range(of: #"\bpath\s+"#, options: .regularExpression) else {
                continue
            }
            let rawPath = line[pathRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let path = safeDevicePath(rawPath)
            members.append(LinuxStorageMemberCandidate(
                role: .data,
                path: path,
                findings: path.flatMap { errorFindings[$0] } ?? []
            ))
            if members.count == maximumMemberCount { break }
        }

        var findings: [StorageHealthFinding] = []
        if sawMissingSummary || members.contains(where: { $0.path == nil }) {
            findings.append(StorageHealthFinding(
                kind: .missingMember,
                severity: .warning,
                source: .btrfs
            ))
        }
        guard !members.isEmpty || sawMissingSummary else { return nil }
        return LinuxStorageTopologyDiscovery(
            kind: .btrfs,
            name: name,
            findings: findings,
            members: members
        )
    }

    static func parseZFSStatus(_ output: String) -> LinuxStorageTopologyDiscovery? {
        let lines = output.components(separatedBy: .newlines)
        guard let poolLine = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("pool:")
        }) else { return nil }

        let name = value(after: "pool:", in: poolLine)
        let poolState = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("state:")
        }).flatMap { value(after: "state:", in: $0) }

        var findings: [StorageHealthFinding] = []
        if let poolState, poolState.uppercased() != "ONLINE" {
            findings.append(StorageHealthFinding(
                kind: .poolState(poolState.uppercased()),
                severity: zfsSeverity(poolState),
                source: .zfs
            ))
        }

        var role = StorageHealthMemberRole.data
        var inConfiguration = false
        var members: [LinuxStorageMemberCandidate] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "config:" { inConfiguration = true; continue }
            guard inConfiguration else { continue }
            if trimmed.hasPrefix("errors:") { break }
            switch trimmed.lowercased() {
            case "logs": role = .log; continue
            case "cache": role = .cache; continue
            case "spares": role = .spare; continue
            case "special", "specials": role = .special; continue
            default: break
            }

            let columns = trimmed.split(whereSeparator: \Character.isWhitespace)
            guard columns.count >= 2 else { continue }
            let rawName = String(columns[0])
            let state = String(columns[1]).uppercased()
            guard rawName.uppercased() != "NAME" else { continue }
            guard !isZFSGroup(rawName, poolName: name) else { continue }

            let path = safeDevicePath(rawName)
            let read = columns.count > 2 ? UInt64(columns[2]) ?? 0 : 0
            let write = columns.count > 3 ? UInt64(columns[3]) ?? 0 : 0
            let checksum = columns.count > 4 ? UInt64(columns[4]) ?? 0 : 0
            var memberFindings: [StorageHealthFinding] = []
            if state != "ONLINE" && state != "AVAIL" {
                memberFindings.append(StorageHealthFinding(
                    kind: .sourceReportedHealth(state),
                    severity: zfsSeverity(state),
                    source: .zfs
                ))
            }
            if read > 0 || write > 0 || checksum > 0 {
                memberFindings.append(StorageHealthFinding(
                    kind: .deviceErrors(read: read, write: write, checksum: checksum),
                    severity: .warning,
                    source: .zfs
                ))
            }
            members.append(LinuxStorageMemberCandidate(
                role: role,
                path: path,
                findings: memberFindings
            ))
            if members.count == maximumMemberCount { break }
        }
        guard !members.isEmpty else { return nil }
        if members.contains(where: { $0.path == nil }) {
            findings.append(StorageHealthFinding(
                kind: .partialCoverage,
                severity: .information,
                source: .zfs
            ))
        }
        return LinuxStorageTopologyDiscovery(
            kind: .zfs,
            name: name,
            findings: findings,
            members: members
        )
    }

    private static func btrfsName(in lines: [String]) -> String? {
        guard let header = lines.first(where: { $0.localizedCaseInsensitiveContains("uuid:") }) else {
            return nil
        }
        if let labelRange = header.range(of: "Label:", options: .caseInsensitive),
           let uuidRange = header.range(of: "uuid:", options: .caseInsensitive),
           labelRange.upperBound < uuidRange.lowerBound {
            let label = header[labelRange.upperBound..<uuidRange.lowerBound]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'")))
            if !label.isEmpty, label.lowercased() != "none" { return String(label.prefix(80)) }
        }
        return nil
    }

    private static func btrfsErrorFindings(_ output: String) -> [String: [StorageHealthFinding]] {
        var counters: [String: (read: UInt64, write: UInt64, checksum: UInt64)] = [:]
        for line in output.components(separatedBy: .newlines).prefix(maximumMemberCount * 8) {
            guard let close = line.firstIndex(of: "]"), line.first == "[" else { continue }
            let path = String(line[line.index(after: line.startIndex)..<close])
            guard safeDevicePath(path) != nil,
                  let separator = line.lastIndex(of: " "),
                  let value = UInt64(line[line.index(after: separator)...]) else { continue }
            let key = line[line.index(after: close)..<separator].lowercased()
            var counter = counters[path] ?? (0, 0, 0)
            if key.contains("read_io_errs") { counter.read = value }
            if key.contains("write_io_errs") { counter.write = value }
            if key.contains("corruption_errs") || key.contains("generation_errs") {
                let addition = counter.checksum.addingReportingOverflow(value)
                counter.checksum = addition.overflow ? UInt64.max : addition.partialValue
            }
            counters[path] = counter
        }
        return counters.reduce(into: [:]) { result, entry in
            let values = entry.value
            guard values.read > 0 || values.write > 0 || values.checksum > 0 else { return }
            result[entry.key] = [StorageHealthFinding(
                kind: .deviceErrors(read: values.read, write: values.write, checksum: values.checksum),
                severity: .warning,
                source: .btrfs
            )]
        }
    }

    private static func isZFSGroup(_ name: String, poolName: String?) -> Bool {
        let lower = name.lowercased()
        return name == poolName
            || lower.range(of: #"^(mirror|raidz[0-9]*|draid[0-9]*|replacing|spare)-[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func zfsSeverity(_ state: String) -> StorageHealthFindingSeverity {
        switch state.uppercased() {
        case "FAULTED", "UNAVAIL", "REMOVED": .critical
        default: .warning
        }
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix, options: .caseInsensitive) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(80))
    }

    private static func safeDevicePath<S: StringProtocol>(_ value: S) -> String? {
        let path = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/dev/"), path.utf8.count <= 4_096,
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            return nil
        }
        return path
    }
}
