import Foundation

nonisolated enum StorageHealthProbe {
    private static let timeout: Duration = .seconds(12)

    private enum Marker {
        static let smartBegin = "__VVTERM_SMARTCTL_BEGIN__"
        static let smartEnd = "__VVTERM_SMARTCTL_END__"
        static let smartMissing = "__VVTERM_SMARTCTL_TOOL_MISSING__"
        static let emmcBegin = "__VVTERM_EMMC_BEGIN__"
        static let emmcEnd = "__VVTERM_EMMC_END__"
        static let emmcMissing = "__VVTERM_EMMC_TOOL_MISSING__"
        static let nativeBegin = "__VVTERM_STORAGE_NATIVE_BEGIN__"
        static let nativeEnd = "__VVTERM_STORAGE_NATIVE_END__"
        static let nativeMissing = "__VVTERM_STORAGE_NATIVE_TOOL_MISSING__"
    }

    static func collect(
        client: SSHClient,
        target: StorageHealthProbeTarget
    ) async throws -> StorageDeviceHealthResult {
        try Task.checkCancellation()
        switch target.kind {
        case .linux(let devicePath, let isEMMC):
            guard isDevicePath(devicePath) else { return .unavailable(.unmapped) }
            let output = try await client.execute(
                linuxCommand(devicePath: devicePath, isEMMC: isEMMC),
                timeout: timeout
            )
            try Task.checkCancellation()
            return parseLinuxOutput(output, target: target)

        case .darwin(let nativeIdentifier, let smartctlDevicePath):
            guard isSafeDarwinIdentifier(nativeIdentifier) else { return .unavailable(.unmapped) }
            if let smartctlDevicePath, !isDevicePath(smartctlDevicePath) {
                return .unavailable(.unmapped)
            }
            let output = try await client.execute(
                darwinCommand(
                    nativeIdentifier: nativeIdentifier,
                    smartctlDevicePath: smartctlDevicePath
                ),
                timeout: timeout
            )
            try Task.checkCancellation()
            return parseDarwinOutput(output, target: target)

        case .windows(let diskNumber):
            guard let command = await windowsCommand(client: client, diskNumber: diskNumber) else {
                return .unavailable(.toolMissing)
            }
            let output = try await client.execute(command, timeout: timeout)
            try Task.checkCancellation()
            return parseWindowsOutput(output, target: target)

        case .freeBSD(let devicePath):
            return try await collectBSD(
                client: client,
                target: target,
                platform: .freeBSD,
                devicePath: devicePath
            )
        case .openBSD(let devicePath):
            return try await collectBSD(
                client: client,
                target: target,
                platform: .openBSD,
                devicePath: devicePath
            )
        case .netBSD(let devicePath):
            return try await collectBSD(
                client: client,
                target: target,
                platform: .netBSD,
                devicePath: devicePath
            )
        }
    }

    static func linuxCommand(devicePath: String, isEMMC: Bool) -> String {
        let device = RemoteTerminalBootstrap.shellQuoted(devicePath)
        var script = basePOSIXScript(device: device)
        if isEMMC {
            script += """

            if command -v mmc >/dev/null 2>&1; then
                printf '%s\n' '\(Marker.emmcBegin)'
                mmc extcsd read \(device) 2>&1 || true
                printf '%s\n' '\(Marker.emmcEnd)'
            else
                printf '%s\n' '\(Marker.emmcMissing)'
            fi
            """
        }
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func darwinCommand(
        nativeIdentifier: String,
        smartctlDevicePath: String?
    ) -> String {
        let native = RemoteTerminalBootstrap.shellQuoted(nativeIdentifier)
        var script = """
        export LC_ALL=C LANG=C
        if command -v diskutil >/dev/null 2>&1; then
            printf '%s\n' '\(Marker.nativeBegin)'
            diskutil info -plist \(native) 2>&1 || true
            printf '%s\n' '\(Marker.nativeEnd)'
        else
            printf '%s\n' '\(Marker.nativeMissing)'
        fi
        """
        if let smartctlDevicePath {
            script += "\n" + basePOSIXScript(
                device: RemoteTerminalBootstrap.shellQuoted(smartctlDevicePath)
            )
        }
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func bsdCommand(platform: BSDPlatform, devicePath: String) -> String {
        let device = RemoteTerminalBootstrap.shellQuoted(devicePath)
        let nativeCommand: String
        let nativeTool: String
        switch platform {
        case .freeBSD:
            nativeTool = "geom"
            let name = RemoteTerminalBootstrap.shellQuoted(
                URL(fileURLWithPath: devicePath).lastPathComponent
            )
            nativeCommand = "geom disk list \(name)"
        case .openBSD, .netBSD:
            nativeTool = "disklabel"
            nativeCommand = "disklabel \(device)"
        }

        let script = """
        export LC_ALL=C LANG=C
        if command -v \(nativeTool) >/dev/null 2>&1; then
            printf '%s\n' '\(Marker.nativeBegin)'
            \(nativeCommand) 2>&1 || true
            printf '%s\n' '\(Marker.nativeEnd)'
        else
            printf '%s\n' '\(Marker.nativeMissing)'
        fi
        \(basePOSIXScript(device: device))
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func windowsScript(diskNumber: UInt32) -> String {
        """
        $ErrorActionPreference = 'Stop'
        Write-Output '\(Marker.nativeBegin)'
        try {
            $disk = Get-Disk -Number \(diskNumber) -ErrorAction Stop
            $reliability = $null
            $reliabilityError = $null
            try {
                $reliability = Get-StorageReliabilityCounter -Disk $disk -ErrorAction Stop
            } catch {
                $reliabilityError = $_.Exception.Message
            }
            $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue |
                Where-Object {
                    ([string]$_.UniqueId -eq [string]$disk.UniqueId) -or
                    ([string]$_.DeviceId -eq [string]$disk.Number)
                } |
                Select-Object -First 1
            [pscustomobject]@{
                FriendlyName = [string]$disk.FriendlyName
                BusType = [string]$disk.BusType
                HealthStatus = [string]$disk.HealthStatus
                OperationalStatus = @($disk.OperationalStatus | ForEach-Object { [string]$_ })
                PhysicalHealthStatus = if ($physical) { [string]$physical.HealthStatus } else { $null }
                PhysicalOperationalStatus = if ($physical) { @($physical.OperationalStatus | ForEach-Object { [string]$_ }) } else { @() }
                Temperature = if ($reliability) { $reliability.Temperature } else { $null }
                TemperatureMax = if ($reliability) { $reliability.TemperatureMax } else { $null }
                Wear = if ($reliability) { $reliability.Wear } else { $null }
                PowerOnHours = if ($reliability) { $reliability.PowerOnHours } else { $null }
                ReadErrorsCorrected = if ($reliability) { $reliability.ReadErrorsCorrected } else { $null }
                ReadErrorsUncorrected = if ($reliability) { $reliability.ReadErrorsUncorrected } else { $null }
                WriteErrorsCorrected = if ($reliability) { $reliability.WriteErrorsCorrected } else { $null }
                WriteErrorsUncorrected = if ($reliability) { $reliability.WriteErrorsUncorrected } else { $null }
                StartStopCycleCount = if ($reliability) { $reliability.StartStopCycleCount } else { $null }
                LoadUnloadCycleCount = if ($reliability) { $reliability.LoadUnloadCycleCount } else { $null }
                ReliabilityError = $reliabilityError
            } | ConvertTo-Json -Depth 4 -Compress
        } catch {
            [pscustomobject]@{ ProbeError = $_.Exception.Message } | ConvertTo-Json -Compress
        }
        Write-Output '\(Marker.nativeEnd)'
        $smartctl = Get-Command -Name smartctl.exe, smartctl -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($smartctl) {
            Write-Output '\(Marker.smartBegin)'
            & $smartctl.Path -q noserial -a -j -- '/dev/pd\(diskNumber)' 2>&1 | ForEach-Object { [string]$_ }
            Write-Output '\(Marker.smartEnd)'
        } else {
            Write-Output '\(Marker.smartMissing)'
        }
        """
    }

    nonisolated enum BSDPlatform: Hashable, Sendable {
        case freeBSD
        case openBSD
        case netBSD
    }

    private static func collectBSD(
        client: SSHClient,
        target: StorageHealthProbeTarget,
        platform: BSDPlatform,
        devicePath: String
    ) async throws -> StorageDeviceHealthResult {
        guard isDevicePath(devicePath) else { return .unavailable(.unmapped) }
        let output = try await client.execute(
            bsdCommand(platform: platform, devicePath: devicePath),
            timeout: timeout
        )
        try Task.checkCancellation()
        return parseBSDOutput(output, target: target)
    }

    private static func basePOSIXScript(device: String) -> String {
        """
        if command -v smartctl >/dev/null 2>&1; then
            printf '%s\n' '\(Marker.smartBegin)'
            smartctl -q noserial -a -j -- \(device) 2>&1 || true
            printf '%s\n' '\(Marker.smartEnd)'
        else
            printf '%s\n' '\(Marker.smartMissing)'
        fi
        """
    }

    private static func windowsCommand(
        client: SSHClient,
        diskNumber: UInt32
    ) async -> String? {
        let environment = await client.remoteEnvironment()
        let script = windowsScript(diskNumber: diskNumber)
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

    private static func parseLinuxOutput(
        _ output: String,
        target: StorageHealthProbeTarget
    ) -> StorageDeviceHealthResult {
        var results: [StorageDeviceHealthResult] = []
        if let smartctl = section(Marker.smartBegin, Marker.smartEnd, in: output) {
            results.append(StorageHealthParser.parseSmartctlJSON(smartctl, deviceID: target.deviceID))
        } else if output.contains(Marker.smartMissing) {
            results.append(.unavailable(.toolMissing))
        }
        if let extCSD = section(Marker.emmcBegin, Marker.emmcEnd, in: output) {
            results.append(StorageHealthParser.parseEMMCExtCSD(extCSD, deviceID: target.deviceID))
        } else if output.contains(Marker.emmcMissing) {
            results.append(.unavailable(.toolMissing))
        }
        return results.isEmpty ? .unavailable(.invalidResponse) : StorageHealthParser.merged(results)
    }

    private static func parseDarwinOutput(
        _ output: String,
        target: StorageHealthProbeTarget
    ) -> StorageDeviceHealthResult {
        var results: [StorageDeviceHealthResult] = []
        if let native = section(Marker.nativeBegin, Marker.nativeEnd, in: output) {
            results.append(StorageHealthParser.parseDarwinPlist(native, deviceID: target.deviceID))
        } else if output.contains(Marker.nativeMissing) {
            results.append(.unavailable(.toolMissing))
        }
        if let smartctl = section(Marker.smartBegin, Marker.smartEnd, in: output) {
            results.append(StorageHealthParser.parseSmartctlJSON(smartctl, deviceID: target.deviceID))
        } else if output.contains(Marker.smartMissing) {
            results.append(.unavailable(.toolMissing))
        }
        return results.isEmpty ? .unavailable(.invalidResponse) : StorageHealthParser.merged(results)
    }

    private static func parseWindowsOutput(
        _ output: String,
        target: StorageHealthProbeTarget
    ) -> StorageDeviceHealthResult {
        var results: [StorageDeviceHealthResult] = []
        if let native = section(Marker.nativeBegin, Marker.nativeEnd, in: output) {
            results.append(StorageHealthParser.parseWindowsNativeJSON(native, deviceID: target.deviceID))
        }
        if let smartctl = section(Marker.smartBegin, Marker.smartEnd, in: output) {
            results.append(StorageHealthParser.parseSmartctlJSON(smartctl, deviceID: target.deviceID))
        } else if output.contains(Marker.smartMissing) {
            results.append(.unavailable(.toolMissing))
        }
        return results.isEmpty ? .unavailable(.invalidResponse) : StorageHealthParser.merged(results)
    }

    private static func parseBSDOutput(
        _ output: String,
        target: StorageHealthProbeTarget
    ) -> StorageDeviceHealthResult {
        var results: [StorageDeviceHealthResult] = []
        if let native = section(Marker.nativeBegin, Marker.nativeEnd, in: output) {
            results.append(StorageHealthParser.parseBSDMetadata(native, deviceID: target.deviceID))
        } else if output.contains(Marker.nativeMissing) {
            results.append(.unavailable(.toolMissing))
        }
        if let smartctl = section(Marker.smartBegin, Marker.smartEnd, in: output) {
            results.append(StorageHealthParser.parseSmartctlJSON(smartctl, deviceID: target.deviceID))
        } else if output.contains(Marker.smartMissing) {
            results.append(.unavailable(.toolMissing))
        }
        return results.isEmpty ? .unavailable(.invalidResponse) : StorageHealthParser.merged(results)
    }

    private static func section(_ begin: String, _ end: String, in output: String) -> String? {
        guard let beginRange = output.range(of: begin),
              let endRange = output.range(of: end, range: beginRange.upperBound..<output.endIndex) else {
            return nil
        }
        return String(output[beginRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDevicePath(_ value: String) -> Bool {
        value.hasPrefix("/dev/") && !value.contains("\n") && !value.contains("\r")
    }

    private static func isSafeDarwinIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        return !value.contains("\n") && !value.contains("\r")
    }
}
