import Foundation

/// The result of mapping a mounted volume to its physical storage topology.
///
/// Resolution deliberately rejects ambiguous leaf mappings. Arrays are
/// represented explicitly so one member is never mistaken for the whole
/// volume.
nonisolated enum StorageHealthTargetResolution: Hashable, Sendable {
    case topology(StorageHealthResolvedTopology)
    case unavailable(StorageHealthUnavailableReason)
}

/// Resolves transient mount metadata into the platform-specific locator used by
/// `StorageHealthProbe`. Raw locators live only for the duration of the request;
/// they are never persisted or copied into user-visible health attributes.
nonisolated enum StorageHealthTargetResolver {
    private static let timeout: Duration = .seconds(6)

    static let resolutionBeginMarker = "__VVTERM_STORAGE_RESOLUTION_BEGIN__"
    static let resolutionEndMarker = "__VVTERM_STORAGE_RESOLUTION_END__"
    static let resolutionToolMissingMarker = "__VVTERM_STORAGE_RESOLUTION_TOOL_MISSING__"
    static let btrfsStatsBeginMarker = "__VVTERM_BTRFS_STATS_BEGIN__"
    static let btrfsStatsEndMarker = "__VVTERM_BTRFS_STATS_END__"

    static func resolve(
        client: SSHClient,
        platform: RemotePlatform,
        volume: VolumeInfo
    ) async throws -> StorageHealthTargetResolution {
        if let unavailableReason = unavailableReason(for: volume) {
            return .unavailable(unavailableReason)
        }

        try Task.checkCancellation()
        let deviceID = StorageDeviceIdentity(
            namespace: platform.rawValue,
            opaqueValue: UUID().uuidString
        )

        switch platform {
        case .linux:
            return try await resolveLinux(client: client, volume: volume, deviceID: deviceID)
        case .darwin:
            return try await resolveDarwin(client: client, volume: volume, deviceID: deviceID)
        case .windows:
            return try await resolveWindows(client: client, volume: volume, deviceID: deviceID)
        case .freebsd, .openbsd, .netbsd:
            return try await resolveBSD(
                client: client,
                platform: platform,
                volume: volume,
                deviceID: deviceID
            )
        case .unknown:
            return .unavailable(.unsupported)
        }
    }

    static func unavailableReason(for volume: VolumeInfo) -> StorageHealthUnavailableReason? {
        switch volume.kind {
        case .network:
            return .networkVolume
        case .container, .virtual:
            return .virtualDevice
        case .physical, .unknown:
            return nil
        }
    }

    // MARK: - Linux

    static func linuxResolutionCommand(source: String, mountPoint: String) -> String? {
        guard isSafeLocator(source), isSafeLocator(mountPoint) else { return nil }

        let source = RemoteTerminalBootstrap.shellQuoted(source)
        let mountPoint = RemoteTerminalBootstrap.shellQuoted(mountPoint)
        let script = """
        export LC_ALL=C LANG=C
        vvterm_source=\(source)
        if command -v findmnt >/dev/null 2>&1; then
            vvterm_candidate=$(findmnt -n -o SOURCE -T \(mountPoint) 2>/dev/null | sed -n '1p')
            case "$vvterm_candidate" in
                /dev/*) vvterm_source=${vvterm_candidate%%\\[*} ;;
            esac
        fi
        if command -v lsblk >/dev/null 2>&1; then
            printf '%s\n' '\(resolutionBeginMarker)'
            lsblk -s -J -p -o PATH,TYPE -- "$vvterm_source" 2>/dev/null || true
            printf '%s\n' '\(resolutionEndMarker)'
        else
            printf '%s\n' '\(resolutionToolMissingMarker)'
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func parseLinuxResolution(
        _ output: String,
        fallbackSource: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageHealthTargetResolution {
        if output.contains(resolutionToolMissingMarker) {
            if let devicePath = recognizedLinuxWholeDevice(fallbackSource) {
                return linuxTarget(devicePath: devicePath, deviceID: deviceID)
            }
            return .unavailable(.toolMissing)
        }

        guard let json = markedSection(in: output),
              let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(LinuxBlockDevices.self, from: data) else {
            return .unavailable(.invalidResponse)
        }

        var diskPaths: Set<String> = []
        var containsCompositeDevice = false
        for node in response.blockdevices {
            collectLinuxResolution(
                node,
                diskPaths: &diskPaths,
                containsCompositeDevice: &containsCompositeDevice
            )
        }

        guard !containsCompositeDevice,
              diskPaths.count == 1,
              let devicePath = diskPaths.first else {
            return .unavailable(.unmapped)
        }
        return linuxTarget(devicePath: devicePath, deviceID: deviceID)
    }

    private static func resolveLinux(
        client: SSHClient,
        volume: VolumeInfo,
        deviceID: StorageDeviceIdentity
    ) async throws -> StorageHealthTargetResolution {
        switch volume.fileSystem.lowercased() {
        case "btrfs":
            return try await resolveLinuxArray(
                client: client,
                command: btrfsDiscoveryCommand(mountPoint: volume.mountPoint),
                parser: { output in
                    guard let filesystem = markedSection(in: output) else { return nil }
                    let stats = section(
                        btrfsStatsBeginMarker,
                        btrfsStatsEndMarker,
                        in: output
                    ) ?? ""
                    return LinuxStorageTopologyParser.parseBTRFS(
                        filesystem: filesystem,
                        deviceStats: stats
                    )
                }
            )
        case "zfs":
            return try await resolveLinuxArray(
                client: client,
                command: zfsDiscoveryCommand(
                    source: volume.source,
                    mountPoint: volume.mountPoint
                ),
                parser: LinuxStorageTopologyParser.parseZFSStatus
            )
        default:
            break
        }

        guard let command = linuxResolutionCommand(
            source: volume.source,
            mountPoint: volume.mountPoint
        ) else {
            return .unavailable(.unmapped)
        }

        let output = try await client.execute(command, timeout: timeout)
        try Task.checkCancellation()
        return parseLinuxResolution(output, fallbackSource: volume.source, deviceID: deviceID)
    }

    static func btrfsDiscoveryCommand(mountPoint: String) -> String? {
        guard isSafeLocator(mountPoint) else { return nil }
        let mountPoint = RemoteTerminalBootstrap.shellQuoted(mountPoint)
        let script = """
        export LC_ALL=C LANG=C
        if command -v btrfs >/dev/null 2>&1; then
            printf '%s\n' '\(resolutionBeginMarker)'
            btrfs filesystem show --raw -- \(mountPoint) 2>&1 || true
            printf '%s\n' '\(resolutionEndMarker)'
            printf '%s\n' '\(btrfsStatsBeginMarker)'
            btrfs device stats -- \(mountPoint) 2>&1 || true
            printf '%s\n' '\(btrfsStatsEndMarker)'
        else
            printf '%s\n' '\(resolutionToolMissingMarker)'
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func zfsDiscoveryCommand(source: String, mountPoint: String) -> String? {
        guard isSafeLocator(source), isSafeLocator(mountPoint) else { return nil }
        let source = RemoteTerminalBootstrap.shellQuoted(source)
        let mountPoint = RemoteTerminalBootstrap.shellQuoted(mountPoint)
        let script = """
        export LC_ALL=C LANG=C
        vvterm_dataset=\(source)
        if command -v findmnt >/dev/null 2>&1; then
            vvterm_candidate=$(findmnt -n -o SOURCE -T \(mountPoint) 2>/dev/null | sed -n '1p')
            case "$vvterm_candidate" in
                '') ;;
                *) vvterm_dataset=$vvterm_candidate ;;
            esac
        fi
        vvterm_pool=${vvterm_dataset%%/*}
        if command -v zpool >/dev/null 2>&1; then
            printf '%s\n' '\(resolutionBeginMarker)'
            zpool status -P "$vvterm_pool" 2>&1 || true
            printf '%s\n' '\(resolutionEndMarker)'
        else
            printf '%s\n' '\(resolutionToolMissingMarker)'
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func linuxDeviceResolutionCommand(devicePath: String) -> String? {
        guard isDevicePath(devicePath) else { return nil }
        let device = RemoteTerminalBootstrap.shellQuoted(devicePath)
        let script = """
        export LC_ALL=C LANG=C
        if command -v lsblk >/dev/null 2>&1; then
            printf '%s\n' '\(resolutionBeginMarker)'
            lsblk -s -J -p -o PATH,TYPE -- \(device) 2>/dev/null || true
            printf '%s\n' '\(resolutionEndMarker)'
        else
            printf '%s\n' '\(resolutionToolMissingMarker)'
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    private static func resolveLinuxArray(
        client: SSHClient,
        command: String?,
        parser: (String) -> LinuxStorageTopologyDiscovery?
    ) async throws -> StorageHealthTargetResolution {
        guard let command else { return .unavailable(.unmapped) }
        let output = try await client.execute(command, timeout: timeout)
        try Task.checkCancellation()
        if output.contains(resolutionToolMissingMarker) {
            return .unavailable(.toolMissing)
        }
        guard let discovery = parser(output) else {
            let normalized = output.lowercased()
            if normalized.contains("permission denied") || normalized.contains("operation not permitted") {
                return .unavailable(.permissionDenied)
            }
            return .unavailable(.invalidResponse)
        }

        var resolvedByKind: [StorageHealthProbeTarget.Kind: (
            ordinal: Int,
            role: StorageHealthMemberRole,
            id: StorageDeviceIdentity,
            findings: [StorageHealthFinding]
        )] = [:]
        var unresolved: [(ordinal: Int, member: StorageHealthResolvedMember)] = []

        for (candidateOrdinal, candidate) in discovery.members
            .prefix(LinuxStorageTopologyParser.maximumMemberCount)
            .enumerated() {
            try Task.checkCancellation()
            let memberID = StorageDeviceIdentity(namespace: "linux", opaqueValue: UUID().uuidString)
            guard let path = candidate.path else {
                unresolved.append((candidateOrdinal, .unresolved(
                    id: memberID,
                    role: candidate.role,
                    reason: .unmapped
                )))
                continue
            }
            guard let mappingCommand = linuxDeviceResolutionCommand(devicePath: path) else {
                unresolved.append((candidateOrdinal, .unresolved(
                    id: memberID,
                    role: candidate.role,
                    reason: .unmapped
                )))
                continue
            }
            let mappingOutput = try await client.execute(mappingCommand, timeout: timeout)
            try Task.checkCancellation()
            let mapping = parseLinuxResolution(
                mappingOutput,
                fallbackSource: path,
                deviceID: memberID
            )
            guard case .topology(let topology) = mapping,
                  case .target(_, let target, _) = topology.members.first else {
                let reason: StorageHealthUnavailableReason
                if case .unavailable(let mappedReason) = mapping { reason = mappedReason } else { reason = .unmapped }
                unresolved.append((candidateOrdinal, .unresolved(
                    id: memberID,
                    role: candidate.role,
                    reason: reason
                )))
                continue
            }
            if var existing = resolvedByKind[target.kind] {
                existing.findings.append(contentsOf: candidate.findings)
                if existing.role != .data, candidate.role == .data { existing.role = .data }
                resolvedByKind[target.kind] = existing
            } else {
                resolvedByKind[target.kind] = (
                    candidateOrdinal,
                    candidate.role,
                    memberID,
                    candidate.findings
                )
            }
        }

        let resolved = resolvedByKind.map { kind, value in
            (ordinal: value.ordinal, member: StorageHealthResolvedMember.target(
                role: value.role,
                StorageHealthProbeTarget(deviceID: value.id, kind: kind),
                findings: value.findings
            ))
        }
        let members = (resolved + unresolved)
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.member)
        guard !members.isEmpty else { return .unavailable(.unmapped) }
        return .topology(StorageHealthResolvedTopology(
            kind: discovery.kind,
            name: discovery.name,
            findings: discovery.findings,
            members: members
        ))
    }

    private static func linuxTarget(
        devicePath: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageHealthTargetResolution {
        guard isDevicePath(devicePath) else { return .unavailable(.unmapped) }
        let name = URL(fileURLWithPath: devicePath).lastPathComponent.lowercased()
        return singleDeviceTopology(StorageHealthProbeTarget(
            deviceID: deviceID,
            kind: .linux(devicePath: devicePath, isEMMC: name.hasPrefix("mmcblk"))
        ))
    }

    private static func collectLinuxResolution(
        _ node: LinuxBlockDevice,
        diskPaths: inout Set<String>,
        containsCompositeDevice: inout Bool
    ) {
        let type = node.type?.lowercased() ?? ""
        if type == "disk", let path = node.path, isDevicePath(path) {
            diskPaths.insert(path)
        } else if type == "md" || type == "mpath" || type == "multipath" || type.hasPrefix("raid") {
            containsCompositeDevice = true
        }
        for child in node.children ?? [] {
            collectLinuxResolution(
                child,
                diskPaths: &diskPaths,
                containsCompositeDevice: &containsCompositeDevice
            )
        }
    }

    private static func recognizedLinuxWholeDevice(_ source: String) -> String? {
        guard isDevicePath(source) else { return nil }
        let name = URL(fileURLWithPath: source).lastPathComponent.lowercased()
        let patterns = [
            #"^(sd|vd|xvd|hd)[a-z]+$"#,
            #"^nvme[0-9]+n[0-9]+$"#,
            #"^mmcblk[0-9]+$"#
        ]
        guard patterns.contains(where: { name.range(of: $0, options: .regularExpression) != nil }) else {
            return nil
        }
        return source
    }

    // MARK: - Darwin

    static func darwinResolutionCommand(identifier: String) -> String? {
        guard isSafeLocator(identifier) else { return nil }
        let identifier = RemoteTerminalBootstrap.shellQuoted(identifier)
        let script = """
        export LC_ALL=C LANG=C
        if command -v diskutil >/dev/null 2>&1; then
            printf '%s\n' '\(resolutionBeginMarker)'
            diskutil info -plist \(identifier) 2>/dev/null || true
            printf '%s\n' '\(resolutionEndMarker)'
        else
            printf '%s\n' '\(resolutionToolMissingMarker)'
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func parseDarwinDiskInfo(_ output: String) -> DarwinDiskInfoResolution? {
        guard let plist = markedSection(in: output),
              let data = plist.data(using: .utf8),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any] else {
            return nil
        }

        let deviceIdentifier = normalizedDarwinIdentifier(dictionary["DeviceIdentifier"] as? String)
        let parentWholeDisk = normalizedDarwinIdentifier(
            (dictionary["ParentWholeDisk"] as? String)
                ?? (dictionary["PartOfWhole"] as? String)
        )
        let isWholeDisk = dictionary["WholeDisk"] as? Bool ?? false
        let isVirtual = isExplicitlyVirtualDarwinDisk(dictionary)
        var physicalStores: Set<String> = []
        collectDarwinIdentifiers(dictionary["APFSPhysicalStores"], into: &physicalStores)

        return DarwinDiskInfoResolution(
            deviceIdentifier: deviceIdentifier,
            parentWholeDisk: parentWholeDisk,
            isWholeDisk: isWholeDisk,
            isVirtual: isVirtual,
            physicalStores: physicalStores.sorted()
        )
    }

    static func darwinUnavailableReason(
        for info: DarwinDiskInfoResolution
    ) -> StorageHealthUnavailableReason? {
        info.isVirtual ? .virtualDevice : nil
    }

    private static func resolveDarwin(
        client: SSHClient,
        volume: VolumeInfo,
        deviceID: StorageDeviceIdentity
    ) async throws -> StorageHealthTargetResolution {
        let initialIdentifier = isSafeLocator(volume.source) && !volume.source.isEmpty
            ? volume.source
            : volume.mountPoint
        guard let command = darwinResolutionCommand(identifier: initialIdentifier) else {
            return .unavailable(.unmapped)
        }

        let output = try await client.execute(command, timeout: timeout)
        try Task.checkCancellation()
        if output.contains(resolutionToolMissingMarker) {
            return .unavailable(.toolMissing)
        }
        guard let info = parseDarwinDiskInfo(output) else {
            return .unavailable(.invalidResponse)
        }
        if let reason = darwinUnavailableReason(for: info) {
            return .unavailable(reason)
        }

        let wholeDisk: String?
        if info.physicalStores.count > 1 {
            return .unavailable(.unmapped)
        } else if let physicalStore = info.physicalStores.first {
            guard let physicalStoreCommand = darwinResolutionCommand(identifier: physicalStore) else {
                return .unavailable(.unmapped)
            }
            let physicalStoreOutput = try await client.execute(physicalStoreCommand, timeout: timeout)
            try Task.checkCancellation()
            guard let physicalStoreInfo = parseDarwinDiskInfo(physicalStoreOutput) else {
                return .unavailable(.invalidResponse)
            }
            if let reason = darwinUnavailableReason(for: physicalStoreInfo) {
                return .unavailable(reason)
            }
            wholeDisk = physicalStoreInfo.wholeDiskIdentifier
        } else {
            wholeDisk = info.wholeDiskIdentifier
        }

        guard let wholeDisk else { return .unavailable(.unmapped) }
        return singleDeviceTopology(StorageHealthProbeTarget(
            deviceID: deviceID,
            kind: .darwin(
                nativeIdentifier: wholeDisk,
                smartctlDevicePath: "/dev/\(wholeDisk)"
            )
        ))
    }

    private static func collectDarwinIdentifiers(_ value: Any?, into identifiers: inout Set<String>) {
        if let identifier = value as? String, let normalized = normalizedDarwinIdentifier(identifier) {
            identifiers.insert(normalized)
        } else if let dictionary = value as? [String: Any] {
            if let identifier = normalizedDarwinIdentifier(dictionary["DeviceIdentifier"] as? String) {
                identifiers.insert(identifier)
            }
            for nested in dictionary.values {
                collectDarwinIdentifiers(nested, into: &identifiers)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectDarwinIdentifiers(nested, into: &identifiers)
            }
        }
    }

    private static func normalizedDarwinIdentifier(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("/dev/") {
            value.removeFirst(5)
        }
        guard value.range(of: #"^disk[0-9]+(?:s[0-9]+)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func isExplicitlyVirtualDarwinDisk(_ dictionary: [String: Any]) -> Bool {
        if dictionary["Virtual"] as? Bool == true || dictionary["DiskImage"] as? Bool == true {
            return true
        }

        let explicitValues = [
            dictionary["VirtualOrPhysical"] as? String,
            dictionary["DeviceLocation"] as? String,
            dictionary["MediaType"] as? String,
            dictionary["Content"] as? String
        ]
        return explicitValues.compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { $0 == "virtual" || $0 == "disk image" || $0 == "diskimage" }
    }

    // MARK: - Windows

    static func windowsResolutionScript(source: String, mountPoint: String) -> String? {
        let driveLetter = windowsDriveLetter(source) ?? windowsDriveLetter(mountPoint)
        let volumeLookup: String
        if let driveLetter {
            volumeLookup = "$volume = @(Get-Volume -DriveLetter '\(driveLetter)' -ErrorAction Stop)"
        } else if isSafeLocator(source), !source.isEmpty {
            let source = powerShellSingleQuoted(source)
            volumeLookup = """
            $vvtermPath = '\(source)'
            $volume = @(Get-Volume -ErrorAction Stop | Where-Object { [string]$_.Path -eq $vvtermPath })
            """
        } else {
            return nil
        }

        return """
        $ErrorActionPreference = 'Stop'
        Write-Output '\(resolutionBeginMarker)'
        try {
            \(volumeLookup)
            $diskNumbers = @(
                $volume |
                    Get-Partition -ErrorAction Stop |
                    Get-Disk -ErrorAction Stop |
                    ForEach-Object { [uint64]$_.Number } |
                    Sort-Object -Unique
            )
            [pscustomobject]@{ DiskNumbers = @($diskNumbers) } | ConvertTo-Json -Depth 3 -Compress
        } catch {
            [pscustomobject]@{ ProbeError = $_.Exception.Message } | ConvertTo-Json -Compress
        }
        Write-Output '\(resolutionEndMarker)'
        """
    }

    static func parseWindowsResolution(
        _ output: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageHealthTargetResolution {
        guard let json = markedSection(in: output),
              let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable(.invalidResponse)
        }

        if let error = value["ProbeError"] as? String {
            let normalized = error.lowercased()
            if normalized.contains("access denied") || normalized.contains("permission") {
                return .unavailable(.permissionDenied)
            }
            if normalized.contains("not recognized") || normalized.contains("not found") {
                return .unavailable(.toolMissing)
            }
            return .unavailable(.unmapped)
        }

        let rawNumbers: [Any]
        if let numbers = value["DiskNumbers"] as? [Any] {
            rawNumbers = numbers
        } else if let number = value["DiskNumbers"] {
            rawNumbers = [number]
        } else {
            return .unavailable(.invalidResponse)
        }

        let diskNumbers = Set(rawNumbers.compactMap(uint32))
        guard rawNumbers.count == diskNumbers.count,
              diskNumbers.count == 1,
              let diskNumber = diskNumbers.first else {
            return .unavailable(.unmapped)
        }

        return singleDeviceTopology(StorageHealthProbeTarget(
            deviceID: deviceID,
            kind: .windows(diskNumber: diskNumber)
        ))
    }

    private static func resolveWindows(
        client: SSHClient,
        volume: VolumeInfo,
        deviceID: StorageDeviceIdentity
    ) async throws -> StorageHealthTargetResolution {
        guard let script = windowsResolutionScript(
            source: volume.source,
            mountPoint: volume.mountPoint
        ) else {
            return .unavailable(.unmapped)
        }
        guard let command = await windowsCommand(client: client, script: script) else {
            return .unavailable(.toolMissing)
        }

        let output = try await client.execute(command, timeout: timeout)
        try Task.checkCancellation()
        return parseWindowsResolution(output, deviceID: deviceID)
    }

    private static func windowsCommand(client: SSHClient, script: String) async -> String? {
        let environment = await client.remoteEnvironment()
        if environment.shellProfile.family == .powershell {
            return script
        }
        guard let executable = environment.powerShellExecutable else { return nil }
        let command = RemoteTerminalBootstrap.wrapPowerShellCommand(
            script,
            executableName: executable
        )
        return environment.shellProfile.family == .cmd
            ? RemoteTerminalBootstrap.wrapCmdExecCommand(command)
            : command
    }

    private static func windowsDriveLetter(_ value: String) -> Character? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let characters = Array(trimmed)
        guard characters[0].isLetter, characters[1] == ":" else { return nil }
        return Character(String(characters[0]).uppercased())
    }

    // MARK: - BSD

    static func bsdResolutionCommand(platform: RemotePlatform) -> String? {
        let key: String
        switch platform {
        case .freebsd:
            key = "kern.disks"
        case .openbsd, .netbsd:
            key = "hw.disknames"
        case .linux, .darwin, .windows, .unknown:
            return nil
        }

        let script = """
        export LC_ALL=C LANG=C
        if command -v sysctl >/dev/null 2>&1; then
            printf '%s\n' '\(resolutionBeginMarker)'
            sysctl -n \(key) 2>/dev/null || true
            printf '%s\n' '\(resolutionEndMarker)'
        else
            printf '%s\n' '\(resolutionToolMissingMarker)'
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func parseBSDResolution(
        _ output: String,
        platform: RemotePlatform,
        source: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageHealthTargetResolution {
        if output.contains(resolutionToolMissingMarker) {
            return .unavailable(.toolMissing)
        }
        guard isDevicePath(source), let diskNames = markedSection(in: output) else {
            return .unavailable(.invalidResponse)
        }

        let candidates = Set(diskNames
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .compactMap { token -> String? in
                let name = token.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                guard name.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
                    return nil
                }
                return name
            })

        let sourceName = URL(fileURLWithPath: source).lastPathComponent.lowercased()
        var sourceNames = [sourceName]
        if sourceName.hasPrefix("r") {
            sourceNames.append(String(sourceName.dropFirst()))
        }
        let matches = candidates.filter { candidate in
            sourceNames.contains { sourceName in
                bsdSource(sourceName, belongsTo: candidate.lowercased(), platform: platform)
            }
        }
        guard matches.count == 1, let diskName = matches.first else {
            return .unavailable(.unmapped)
        }

        let devicePath: String
        let kind: StorageHealthProbeTarget.Kind
        switch platform {
        case .freebsd:
            devicePath = "/dev/\(diskName)"
            kind = .freeBSD(devicePath: devicePath)
        case .openbsd:
            devicePath = "/dev/\(diskName)c"
            kind = .openBSD(devicePath: devicePath)
        case .netbsd:
            devicePath = "/dev/\(diskName)d"
            kind = .netBSD(devicePath: devicePath)
        case .linux, .darwin, .windows, .unknown:
            return .unavailable(.unsupported)
        }

        return singleDeviceTopology(StorageHealthProbeTarget(deviceID: deviceID, kind: kind))
    }

    private static func resolveBSD(
        client: SSHClient,
        platform: RemotePlatform,
        volume: VolumeInfo,
        deviceID: StorageDeviceIdentity
    ) async throws -> StorageHealthTargetResolution {
        guard isSafeLocator(volume.source),
              let command = bsdResolutionCommand(platform: platform) else {
            return .unavailable(.unmapped)
        }

        let output = try await client.execute(command, timeout: timeout)
        try Task.checkCancellation()
        return parseBSDResolution(
            output,
            platform: platform,
            source: volume.source,
            deviceID: deviceID
        )
    }

    private static func bsdSource(
        _ sourceName: String,
        belongsTo diskName: String,
        platform: RemotePlatform
    ) -> Bool {
        guard sourceName.hasPrefix(diskName) else { return false }
        let suffix = String(sourceName.dropFirst(diskName.count))
        switch platform {
        case .freebsd:
            if suffix.isEmpty { return true }
            return suffix.range(
                of: #"^(p[0-9]+|s[0-9]+[a-z]?)$"#,
                options: .regularExpression
            ) != nil
        case .openbsd, .netbsd:
            return suffix.count == 1 && suffix.first?.isLetter == true
        case .linux, .darwin, .windows, .unknown:
            return false
        }
    }

    // MARK: - Shared parsing and validation

    static func markedSection(in output: String) -> String? {
        guard let begin = output.range(of: resolutionBeginMarker),
              let end = output.range(
                of: resolutionEndMarker,
                range: begin.upperBound..<output.endIndex
              ) else {
            return nil
        }
        return String(output[begin.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func section(_ beginMarker: String, _ endMarker: String, in output: String) -> String? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex) else {
            return nil
        }
        return String(output[begin.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSafeLocator(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func isDevicePath(_ value: String) -> Bool {
        value.hasPrefix("/dev/") && isSafeLocator(value)
    }

    private static func powerShellSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func uint32(_ value: Any) -> UInt32? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite,
                  double >= 0,
                  double <= Double(UInt32.max),
                  double.rounded(.towardZero) == double else {
                return nil
            }
            return UInt32(double)
        }
        if let string = value as? String, let value = UInt64(string), value <= UInt64(UInt32.max) {
            return UInt32(value)
        }
        return nil
    }

    private static func singleDeviceTopology(
        _ target: StorageHealthProbeTarget
    ) -> StorageHealthTargetResolution {
        .topology(StorageHealthResolvedTopology(
            kind: .physicalDevice,
            name: nil,
            findings: [],
            members: [.target(role: .data, target, findings: [])]
        ))
    }
}

nonisolated struct DarwinDiskInfoResolution: Equatable, Sendable {
    let deviceIdentifier: String?
    let parentWholeDisk: String?
    let isWholeDisk: Bool
    let isVirtual: Bool
    let physicalStores: [String]

    var wholeDiskIdentifier: String? {
        if let parentWholeDisk { return parentWholeDisk }
        guard isWholeDisk,
              let deviceIdentifier,
              deviceIdentifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return deviceIdentifier
    }
}

private nonisolated struct LinuxBlockDevices: Decodable {
    let blockdevices: [LinuxBlockDevice]
}

private nonisolated struct LinuxBlockDevice: Decodable {
    let path: String?
    let type: String?
    let children: [LinuxBlockDevice]?
}
