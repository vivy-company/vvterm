import CoreFoundation
import Foundation

nonisolated enum StorageHealthParser {
    static func parseSmartctlJSON(
        _ output: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageDeviceHealthResult {
        guard let object = jsonDictionary(in: output) else {
            return .unavailable(unavailableReason(for: output))
        }

        var state: StorageHealthState = .unknown
        var metrics = StorageHealthMetrics()
        var findings: [StorageHealthFinding] = []
        var attributes: [StorageHealthAttribute] = []

        if let passed = bool(at: ["smart_status", "passed"], in: object) {
            state = passed ? .healthy : .failing
            if !passed {
                findings.append(StorageHealthFinding(
                    kind: .smartOverallFailure,
                    severity: .critical,
                    source: .smartctl
                ))
            }
        }

        let exitStatus = uint64(at: ["smartctl", "exit_status"], in: object) ?? 0
        if exitStatus & 0x08 != 0 {
            state = maxState(state, .failing)
            appendUnique(StorageHealthFinding(
                kind: .smartOverallFailure,
                severity: .critical,
                source: .smartctl
            ), to: &findings)
        }
        if exitStatus & 0x10 != 0 {
            findings.append(StorageHealthFinding(
                kind: .smartCurrentPrefailThreshold,
                severity: .warning,
                source: .smartctl
            ))
        }
        if exitStatus & 0x20 != 0 {
            findings.append(StorageHealthFinding(
                kind: .smartPastThreshold,
                severity: .information,
                timing: .historical,
                source: .smartctl
            ))
        }
        if exitStatus & 0x40 != 0 {
            findings.append(StorageHealthFinding(
                kind: .smartErrorLog,
                severity: .information,
                timing: .historical,
                source: .smartctl
            ))
        }
        if exitStatus & 0x80 != 0 {
            findings.append(StorageHealthFinding(
                kind: .smartSelfTestLog,
                severity: .information,
                timing: .historical,
                source: .smartctl
            ))
        }

        metrics.temperatureCelsius = finiteDouble(at: ["temperature", "current"], in: object)
            ?? finiteDouble(at: ["nvme_smart_health_information_log", "temperature"], in: object)
            ?? finiteDouble(at: ["scsi_temperature", "current"], in: object)
        metrics.maximumTemperatureCelsius = finiteDouble(at: ["temperature", "drive_trip"], in: object)
            ?? finiteDouble(at: ["scsi_temperature", "drive_trip"], in: object)
        metrics.powerOnHours = uint64(at: ["power_on_time", "hours"], in: object)
            ?? uint64(at: ["nvme_smart_health_information_log", "power_on_hours"], in: object)
        metrics.powerCycleCount = uint64(at: ["power_cycle_count"], in: object)
            ?? uint64(at: ["nvme_smart_health_information_log", "power_cycles"], in: object)
        metrics.percentageUsed = finiteDouble(
            at: ["nvme_smart_health_information_log", "percentage_used"],
            in: object
        )
        metrics.availableSparePercent = finiteDouble(
            at: ["nvme_smart_health_information_log", "available_spare"],
            in: object
        )
        metrics.availableSpareThresholdPercent = finiteDouble(
            at: ["nvme_smart_health_information_log", "available_spare_threshold"],
            in: object
        )
        metrics.unsafeShutdownCount = uint64(
            at: ["nvme_smart_health_information_log", "unsafe_shutdowns"],
            in: object
        )
        metrics.mediaErrorCount = uint64(
            at: ["nvme_smart_health_information_log", "media_errors"],
            in: object
        )
        metrics.errorLogEntryCount = uint64(
            at: ["nvme_smart_health_information_log", "num_err_log_entries"],
            in: object
        )

        if let criticalWarning = uint64(
            at: ["nvme_smart_health_information_log", "critical_warning"],
            in: object
        ), criticalWarning > 0 {
            for bit in UInt8(0)..<UInt8(8) where criticalWarning & (1 << bit) != 0 {
                findings.append(StorageHealthFinding(
                    kind: .nvmeCriticalWarning(bit: bit),
                    severity: .warning,
                    source: .smartctl
                ))
            }
        }

        parseSCSIMetrics(from: object, into: &metrics)
        let scsiReadErrors = uint64(
            at: ["scsi_error_counter_log", "read", "total_uncorrected_errors"],
            in: object
        ) ?? 0
        let scsiWriteErrors = uint64(
            at: ["scsi_error_counter_log", "write", "total_uncorrected_errors"],
            in: object
        ) ?? 0
        let scsiMediaErrors = uint64(at: ["scsi_grown_defect_list"], in: object) ?? 0
        if scsiReadErrors > 0 || scsiWriteErrors > 0 || scsiMediaErrors > 0 {
            findings.append(StorageHealthFinding(
                kind: .scsiErrorHistory(
                    read: scsiReadErrors,
                    write: scsiWriteErrors,
                    media: scsiMediaErrors
                ),
                severity: .information,
                timing: .historical,
                source: .smartctl
            ))
        }
        parseATAAttributes(
            from: object,
            findings: &findings,
            attributes: &attributes
        )
        appendSafeSmartctlMetadata(from: object, to: &attributes)

        let messages = smartctlMessages(in: object)
        if !hasHealthData(
            state: state,
            metrics: metrics,
            findings: findings,
            attributes: attributes
        ) {
            if exitStatus & 0x06 != 0 || !messages.isEmpty {
                return .unavailable(unavailableReason(for: messages.joined(separator: "\n")))
            }
            return .unavailable(.invalidResponse)
        }

        return .report(StorageHealthReport(
            deviceID: deviceID,
            state: state,
            metrics: metrics,
            sources: [.smartctl],
            findings: normalizedFindings(findings),
            attributes: normalizedAttributes(attributes)
        ))
    }

    static func parseEMMCExtCSD(
        _ output: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageDeviceHealthResult {
        var preEOLRaw: UInt8?
        var lifetimeARaw: UInt8?
        var lifetimeBRaw: UInt8?

        for line in output.components(separatedBy: .newlines) {
            let uppercased = line.uppercased()
            guard let value = trailingByte(in: line) else { continue }
            if uppercased.contains("PRE_EOL_INFO") {
                preEOLRaw = value
            } else if uppercased.contains("DEVICE_LIFE_TIME_EST_TYP_A") {
                lifetimeARaw = value
            } else if uppercased.contains("DEVICE_LIFE_TIME_EST_TYP_B") {
                lifetimeBRaw = value
            }
        }

        guard preEOLRaw != nil || lifetimeARaw != nil || lifetimeBRaw != nil else {
            return .unavailable(unavailableReason(for: output))
        }

        let preEOL = EMMCPreEOLStatus(rawValue: preEOLRaw ?? 0) ?? .unknown
        let lifetimeA = lifetimeARaw.map(EMMCLifetimeEstimate.init(rawValue:))
        let lifetimeB = lifetimeBRaw.map(EMMCLifetimeEstimate.init(rawValue:))
        let emmc = EMMCHealth(preEOL: preEOL, lifetimeTypeA: lifetimeA, lifetimeTypeB: lifetimeB)

        var state: StorageHealthState
        switch preEOL {
        case .normal:
            state = .healthy
        case .warning, .urgent:
            state = .warning
        case .unknown:
            state = .unknown
        }
        if lifetimeA?.bucket == .exceededMaximumEstimate
            || lifetimeB?.bucket == .exceededMaximumEstimate {
            state = maxState(state, .warning)
        }

        var metrics = StorageHealthMetrics()
        metrics.emmc = emmc
        var findings: [StorageHealthFinding] = []
        if preEOL == .warning || preEOL == .urgent {
            findings.append(StorageHealthFinding(
                kind: .emmcPreEOL(preEOL),
                severity: preEOL == .urgent ? .critical : .warning,
                source: .emmc
            ))
        }
        if lifetimeA?.bucket == .exceededMaximumEstimate
            || lifetimeB?.bucket == .exceededMaximumEstimate {
            findings.append(StorageHealthFinding(
                kind: .emmcLifetimeExceeded,
                severity: .warning,
                source: .emmc
            ))
        }
        return .report(StorageHealthReport(
            deviceID: deviceID,
            state: state,
            metrics: metrics,
            sources: [.emmc],
            findings: findings
        ))
    }

    static func parseDarwinPlist(
        _ output: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageDeviceHealthResult {
        guard let data = plistData(in: output) else {
            return .unavailable(unavailableReason(for: output))
        }
        return parseDarwinPlist(data, deviceID: deviceID)
    }

    static func parseDarwinPlist(
        _ data: Data,
        deviceID: StorageDeviceIdentity
    ) -> StorageDeviceHealthResult {
        guard
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let object = propertyList as? [String: Any]
        else {
            return .unavailable(.invalidResponse)
        }

        let smartStatus = string(object["SMARTStatus"])
        let state = darwinSMARTState(smartStatus)
        var metrics = StorageHealthMetrics()
        var findings = sourceHealthFindings(state: state, status: smartStatus, source: .darwinDiskUtility)
        var attributes: [StorageHealthAttribute] = []

        appendTextAttribute(key: "device.model", label: "Model", value: string(object["MediaName"]), to: &attributes)
        appendTextAttribute(key: "device.transport", label: "Connection", value: string(object["BusProtocol"]), to: &attributes)
        if let solidState = bool(object["SolidState"]) {
            attributes.append(StorageHealthAttribute(
                key: "device.solid_state",
                label: "Solid State",
                value: .boolean(solidState)
            ))
        }
        if let internalDevice = bool(object["Internal"]) {
            attributes.append(StorageHealthAttribute(
                key: "device.internal",
                label: "Internal",
                value: .boolean(internalDevice)
            ))
        }
        appendTextAttribute(
            key: "device.virtual_or_physical",
            label: "Device Type",
            value: string(object["VirtualOrPhysical"]),
            to: &attributes
        )

        if let native = object["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] {
            if let temperature = finiteDouble(native["TEMPERATURE"]) {
                metrics.temperatureCelsius = temperature > 200 ? temperature - 273.15 : temperature
            }
            metrics.percentageUsed = finiteDouble(native["PERCENTAGE_USED"])
            metrics.availableSparePercent = finiteDouble(native["AVAILABLE_SPARE"])
            metrics.availableSpareThresholdPercent = finiteDouble(native["AVAILABLE_SPARE_THRESHOLD"])
            metrics.powerOnHours = splitCounter("POWER_ON_HOURS", in: native, attributes: &attributes)
            metrics.powerCycleCount = splitCounter("POWER_CYCLES", in: native, attributes: &attributes)
            metrics.unsafeShutdownCount = splitCounter("UNSAFE_SHUTDOWNS", in: native, attributes: &attributes)
            metrics.mediaErrorCount = splitCounter("MEDIA_ERRORS", in: native, attributes: &attributes)
            metrics.errorLogEntryCount = splitCounter(
                "NUM_ERROR_INFO_LOG_ENTRIES",
                in: native,
                attributes: &attributes
            )

            if (metrics.mediaErrorCount ?? 0) > 0 || (metrics.errorLogEntryCount ?? 0) > 0 {
                findings.append(StorageHealthFinding(
                    kind: .smartErrorLog,
                    severity: .information,
                    timing: .historical,
                    source: .darwinDiskUtility
                ))
            }
        }

        guard hasHealthData(state: state, metrics: metrics, attributes: attributes) else {
            return .unavailable(.unsupported)
        }
        return .report(StorageHealthReport(
            deviceID: deviceID,
            state: state,
            metrics: metrics,
            sources: [.darwinDiskUtility],
            findings: normalizedFindings(findings),
            attributes: normalizedAttributes(attributes)
        ))
    }

    static func parseWindowsNativeJSON(
        _ output: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageDeviceHealthResult {
        guard let object = jsonDictionary(in: output) else {
            return .unavailable(unavailableReason(for: output))
        }
        if let probeError = string(object["ProbeError"]), !probeError.isEmpty {
            return .unavailable(unavailableReason(for: probeError))
        }

        let diskStatus = string(object["HealthStatus"])
        let physicalStatus = string(object["PhysicalHealthStatus"])
        var state = windowsHealthState(diskStatus)
        state = maxState(state, windowsHealthState(physicalStatus))
        var findings = sourceHealthFindings(
            state: windowsHealthState(diskStatus),
            status: diskStatus,
            source: .windowsStorage
        )
        findings += sourceHealthFindings(
            state: windowsHealthState(physicalStatus),
            status: physicalStatus,
            source: .windowsStorage
        )

        var metrics = StorageHealthMetrics()
        metrics.temperatureCelsius = positiveDouble(object["Temperature"])
        metrics.maximumTemperatureCelsius = positiveDouble(object["TemperatureMax"])
        if let wear = finiteDouble(object["Wear"]), (0...100).contains(wear) {
            metrics.percentageUsed = wear
        }
        metrics.powerOnHours = uint64(object["PowerOnHours"])
        metrics.readErrorsCorrected = uint64(object["ReadErrorsCorrected"])
        metrics.readErrorsUncorrected = uint64(object["ReadErrorsUncorrected"])
        metrics.writeErrorsCorrected = uint64(object["WriteErrorsCorrected"])
        metrics.writeErrorsUncorrected = uint64(object["WriteErrorsUncorrected"])
        metrics.startStopCycleCount = uint64(object["StartStopCycleCount"])
        metrics.loadUnloadCycleCount = uint64(object["LoadUnloadCycleCount"])

        if (metrics.readErrorsUncorrected ?? 0) > 0 || (metrics.writeErrorsUncorrected ?? 0) > 0 {
            findings.append(StorageHealthFinding(
                kind: .sourceReportedHealth("Uncorrected I/O errors"),
                severity: .warning,
                source: .windowsStorage
            ))
        }

        var attributes: [StorageHealthAttribute] = []
        appendTextAttribute(key: "device.model", label: "Model", value: string(object["FriendlyName"]), to: &attributes)
        appendTextAttribute(key: "device.transport", label: "Connection", value: string(object["BusType"]), to: &attributes)
        appendTextAttribute(
            key: "windows.operational_status",
            label: "Operational Status",
            value: joinedString(object["OperationalStatus"]),
            to: &attributes
        )
        appendTextAttribute(
            key: "windows.physical_operational_status",
            label: "Physical Disk Status",
            value: joinedString(object["PhysicalOperationalStatus"]),
            to: &attributes
        )

        guard hasHealthData(state: state, metrics: metrics, attributes: attributes) else {
            let reliabilityError = string(object["ReliabilityError"]) ?? ""
            return .unavailable(
                reliabilityError.isEmpty ? .unsupported : unavailableReason(for: reliabilityError)
            )
        }

        return .report(StorageHealthReport(
            deviceID: deviceID,
            state: state,
            metrics: metrics,
            sources: [.windowsStorage],
            findings: normalizedFindings(findings),
            attributes: normalizedAttributes(attributes)
        ))
    }

    static func parseBSDMetadata(
        _ output: String,
        deviceID: StorageDeviceIdentity
    ) -> StorageDeviceHealthResult {
        let allowedKeys: [String: (key: String, label: String, unit: String?)] = [
            "descr": ("device.model", "Model", nil),
            "description": ("device.model", "Model", nil),
            "model": ("device.model", "Model", nil),
            "label": ("device.label", "Label", nil),
            "type": ("device.type", "Type", nil),
            "mediasize": ("device.media_size", "Media Size", nil),
            "sectorsize": ("device.sector_size", "Sector Size", "bytes"),
            "rotationrate": ("device.rotation_rate", "Rotation Rate", "RPM")
        ]
        var attributes: [StorageHealthAttribute] = []

        for line in output.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let rawKey = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let allowed = allowedKeys[rawKey] else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if allowed.key == "device.media_size", let openParen = value.firstIndex(of: "(") {
                value = String(value[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let safe = safeDisplayText(value), !safe.isEmpty else { continue }
            let attributeValue: StorageHealthAttributeValue
            if let integer = UInt64(safe.components(separatedBy: .whitespaces).first ?? "") {
                attributeValue = .integer(integer)
            } else {
                attributeValue = .text(safe)
            }
            attributes.append(StorageHealthAttribute(
                key: allowed.key,
                label: allowed.label,
                value: attributeValue,
                unit: allowed.unit
            ))
        }

        guard !attributes.isEmpty else {
            return .unavailable(unavailableReason(for: output))
        }
        return .report(StorageHealthReport(
            deviceID: deviceID,
            state: .unknown,
            sources: [.bsdNative],
            attributes: normalizedAttributes(attributes)
        ))
    }

    static func merged(_ results: [StorageDeviceHealthResult]) -> StorageDeviceHealthResult {
        let reports = results.compactMap { result -> StorageHealthReport? in
            guard case .report(let report) = result else { return nil }
            return report
        }
        guard var merged = reports.first else {
            return .unavailable(preferredUnavailableReason(in: results))
        }

        for report in reports.dropFirst() where report.deviceID == merged.deviceID {
            merged.sourceState = maxState(merged.sourceState, report.sourceState)
            merged.metrics = mergedMetrics(merged.metrics, report.metrics)
            merged.sources.formUnion(report.sources)
            merged.findings = normalizedFindings(merged.findings + report.findings)
            merged.attributes = normalizedAttributes(merged.attributes + report.attributes)
        }
        return .report(merged)
    }

    private static func parseSCSIMetrics(
        from object: [String: Any],
        into metrics: inout StorageHealthMetrics
    ) {
        metrics.startStopCycleCount = metrics.startStopCycleCount
            ?? uint64(at: ["scsi_start_stop_cycle_counter", "accumulated_start_stop_cycles"], in: object)
        metrics.loadUnloadCycleCount = metrics.loadUnloadCycleCount
            ?? uint64(at: ["scsi_start_stop_cycle_counter", "accumulated_load_unload_cycles"], in: object)
        metrics.mediaErrorCount = metrics.mediaErrorCount
            ?? uint64(at: ["scsi_grown_defect_list"], in: object)
        metrics.readErrorsCorrected = uint64(
            at: ["scsi_error_counter_log", "read", "total_errors_corrected"],
            in: object
        )
        metrics.readErrorsUncorrected = uint64(
            at: ["scsi_error_counter_log", "read", "total_uncorrected_errors"],
            in: object
        )
        metrics.writeErrorsCorrected = uint64(
            at: ["scsi_error_counter_log", "write", "total_errors_corrected"],
            in: object
        )
        metrics.writeErrorsUncorrected = uint64(
            at: ["scsi_error_counter_log", "write", "total_uncorrected_errors"],
            in: object
        )
    }

    private static func parseATAAttributes(
        from object: [String: Any],
        findings: inout [StorageHealthFinding],
        attributes: inout [StorageHealthAttribute]
    ) {
        guard
            let ata = object["ata_smart_attributes"] as? [String: Any],
            let table = ata["table"] as? [[String: Any]]
        else { return }

        for row in table.prefix(256) {
            guard let id = uint64(row["id"]), id <= 255 else { continue }
            let name = safeDisplayText(string(row["name"]) ?? "SMART Attribute \(id)") ?? "SMART Attribute \(id)"
            let whenFailed = (string(row["when_failed"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !whenFailed.isEmpty && whenFailed != "-" {
                let historical = whenFailed.lowercased().contains("past")
                findings.append(StorageHealthFinding(
                    kind: .ataAttribute(name: humanizedATAName(name)),
                    severity: historical ? .information : .warning,
                    timing: historical ? .historical : .current,
                    source: .smartctl
                ))
            }
            guard
                let raw = row["raw"] as? [String: Any],
                let rawValue = uint64(raw["value"])
            else { continue }
            guard !isRedundantOrMisleadingATAAttribute(id: id, name: name) else { continue }
            attributes.append(StorageHealthAttribute(
                key: "smart.ata.\(id)",
                label: humanizedATAName(name),
                value: .integer(rawValue)
            ))
        }
    }

    private static func appendSafeSmartctlMetadata(
        from object: [String: Any],
        to attributes: inout [StorageHealthAttribute]
    ) {
        appendTextAttribute(key: "device.model", label: "Model", value: string(object["model_name"]), to: &attributes)
        appendTextAttribute(key: "device.firmware", label: "Firmware", value: string(object["firmware_version"]), to: &attributes)
        appendTextAttribute(key: "device.protocol", label: "Protocol", value: string(object["interface_protocol"]), to: &attributes)
        if let device = object["device"] as? [String: Any] {
            appendTextAttribute(key: "device.type", label: "Device Type", value: string(device["protocol"]), to: &attributes)
        }
    }

    private static func splitCounter(
        _ key: String,
        in object: [String: Any],
        attributes: inout [StorageHealthAttribute]
    ) -> UInt64? {
        let low = uint64(object["\(key)_0"])
        let high = uint64(object["\(key)_1"])
        guard let low else { return nil }
        guard let high, high > 0 else { return low }

        let value = String(format: "0x%016llX%016llX", high, low)
        attributes.append(StorageHealthAttribute(
            key: "darwin.\(key.lowercased())",
            label: key.replacingOccurrences(of: "_", with: " ").capitalized,
            value: .text(value)
        ))
        return nil
    }

    private static func mergedMetrics(
        _ first: StorageHealthMetrics,
        _ second: StorageHealthMetrics
    ) -> StorageHealthMetrics {
        var result = first
        result.temperatureCelsius = result.temperatureCelsius ?? second.temperatureCelsius
        result.maximumTemperatureCelsius = result.maximumTemperatureCelsius ?? second.maximumTemperatureCelsius
        result.percentageUsed = result.percentageUsed ?? second.percentageUsed
        result.availableSparePercent = result.availableSparePercent ?? second.availableSparePercent
        result.availableSpareThresholdPercent = result.availableSpareThresholdPercent ?? second.availableSpareThresholdPercent
        result.powerOnHours = result.powerOnHours ?? second.powerOnHours
        result.powerCycleCount = result.powerCycleCount ?? second.powerCycleCount
        result.unsafeShutdownCount = result.unsafeShutdownCount ?? second.unsafeShutdownCount
        result.mediaErrorCount = result.mediaErrorCount ?? second.mediaErrorCount
        result.errorLogEntryCount = result.errorLogEntryCount ?? second.errorLogEntryCount
        result.readErrorsCorrected = result.readErrorsCorrected ?? second.readErrorsCorrected
        result.readErrorsUncorrected = result.readErrorsUncorrected ?? second.readErrorsUncorrected
        result.writeErrorsCorrected = result.writeErrorsCorrected ?? second.writeErrorsCorrected
        result.writeErrorsUncorrected = result.writeErrorsUncorrected ?? second.writeErrorsUncorrected
        result.startStopCycleCount = result.startStopCycleCount ?? second.startStopCycleCount
        result.loadUnloadCycleCount = result.loadUnloadCycleCount ?? second.loadUnloadCycleCount
        result.emmc = result.emmc ?? second.emmc
        return result
    }

    private static func hasHealthData(
        state: StorageHealthState,
        metrics: StorageHealthMetrics,
        findings: [StorageHealthFinding] = [],
        attributes: [StorageHealthAttribute]
    ) -> Bool {
        state != .unknown
            || metrics.temperatureCelsius != nil
            || metrics.maximumTemperatureCelsius != nil
            || metrics.percentageUsed != nil
            || metrics.availableSparePercent != nil
            || metrics.availableSpareThresholdPercent != nil
            || metrics.powerOnHours != nil
            || metrics.powerCycleCount != nil
            || metrics.unsafeShutdownCount != nil
            || metrics.mediaErrorCount != nil
            || metrics.errorLogEntryCount != nil
            || metrics.readErrorsCorrected != nil
            || metrics.readErrorsUncorrected != nil
            || metrics.writeErrorsCorrected != nil
            || metrics.writeErrorsUncorrected != nil
            || metrics.startStopCycleCount != nil
            || metrics.loadUnloadCycleCount != nil
            || metrics.emmc != nil
            || !findings.isEmpty
            || !attributes.isEmpty
    }

    private static func preferredUnavailableReason(in results: [StorageDeviceHealthResult]) -> StorageHealthUnavailableReason {
        let reasons = results.compactMap { result -> StorageHealthUnavailableReason? in
            guard case .unavailable(let reason) = result else { return nil }
            return reason
        }
        let preference: [StorageHealthUnavailableReason] = [
            .permissionDenied, .toolMissing, .virtualDevice, .networkVolume,
            .unmapped, .unsupported, .invalidResponse
        ]
        return preference.first(where: reasons.contains) ?? .invalidResponse
    }

    private static func maxState(_ first: StorageHealthState, _ second: StorageHealthState) -> StorageHealthState {
        first.rawValue >= second.rawValue ? first : second
    }

    private static func unavailableReason(for output: String) -> StorageHealthUnavailableReason {
        let lowercased = output.lowercased()
        if lowercased.contains("permission denied")
            || lowercased.contains("operation not permitted")
            || lowercased.contains("access is denied")
            || lowercased.contains("administrator privilege")
            || lowercased.contains("must be root") {
            return .permissionDenied
        }
        if lowercased.contains("command not found")
            || lowercased.contains("not recognized as the name")
            || lowercased.contains("tool_missing")
            || lowercased.contains("no such file or directory") {
            return .toolMissing
        }
        if lowercased.contains("not supported")
            || lowercased.contains("unsupported")
            || lowercased.contains("unknown device")
            || lowercased.contains("unable to detect device") {
            return .unsupported
        }
        return .invalidResponse
    }

    private static func windowsHealthState(_ value: String?) -> StorageHealthState {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "healthy", "ok":
            return .healthy
        case "warning", "degraded", "predictive failure", "stressed":
            return .warning
        case "unhealthy", "failed", "error", "lost communication":
            return .failing
        default:
            return .unknown
        }
    }

    private static func darwinSMARTState(_ value: String?) -> StorageHealthState {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "verified", "passing":
            return .healthy
        case "failing", "failed":
            return .failing
        case "warning":
            return .warning
        default:
            return .unknown
        }
    }

    private static func smartctlMessages(in object: [String: Any]) -> [String] {
        guard
            let smartctl = object["smartctl"] as? [String: Any],
            let messages = smartctl["messages"] as? [[String: Any]]
        else { return [] }
        return messages.compactMap { string($0["string"]) }
    }

    private static func jsonDictionary(in output: String) -> [String: Any]? {
        guard let data = jsonData(in: output),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let dictionary = object as? [String: Any] {
            return dictionary
        }
        if let array = object as? [[String: Any]] {
            return array.first
        }
        return nil
    }

    private static func jsonData(in output: String) -> Data? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opening = output[start]
        let closing: Character = opening == "{" ? "}" : "]"
        guard let end = output.lastIndex(of: closing), end >= start else { return nil }
        return String(output[start...end]).data(using: .utf8)
    }

    private static func plistData(in output: String) -> Data? {
        if let start = output.range(of: "<?xml")?.lowerBound,
           let endRange = output.range(of: "</plist>", options: .backwards) {
            return String(output[start..<endRange.upperBound]).data(using: .utf8)
        }
        if let start = output.range(of: "bplist")?.lowerBound {
            return String(output[start...]).data(using: .isoLatin1)
        }
        return output.data(using: .utf8)
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        var value: Any = object
        for component in path {
            guard let dictionary = value as? [String: Any], let next = dictionary[component] else {
                return nil
            }
            value = next
        }
        return value
    }

    private static func uint64(at path: [String], in object: [String: Any]) -> UInt64? {
        uint64(value(at: path, in: object))
    }

    private static func finiteDouble(at path: [String], in object: [String: Any]) -> Double? {
        finiteDouble(value(at: path, in: object))
    }

    private static func bool(at path: [String], in object: [String: Any]) -> Bool? {
        bool(value(at: path, in: object))
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let value, !isBoolean(value) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return UInt64(trimmed)
        }
        if let number = value as? NSNumber {
            let decimal = number.stringValue
            guard !decimal.hasPrefix("-") else { return nil }
            return UInt64(decimal)
        }
        return nil
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let value, !isBoolean(value) else { return nil }
        let parsed: Double?
        if let number = value as? NSNumber {
            parsed = number.doubleValue
        } else if let string = value as? String {
            parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private static func positiveDouble(_ value: Any?) -> Double? {
        guard let parsed = finiteDouble(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value, isBoolean(value), let number = value as? NSNumber {
            return number.boolValue
        }
        if let number = value as? NSNumber {
            switch number.intValue {
            case 0 where number.doubleValue == 0: return false
            case 1 where number.doubleValue == 1: return true
            default: return nil
            }
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let value, !isBoolean(value), let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func joinedString(_ value: Any?) -> String? {
        if let string = string(value) { return string }
        if let values = value as? [Any] {
            let strings = values.compactMap(string)
            return strings.isEmpty ? nil : strings.joined(separator: ", ")
        }
        return nil
    }

    private static func appendTextAttribute(
        key: String,
        label: String,
        value: String?,
        to attributes: inout [StorageHealthAttribute]
    ) {
        guard let value, let safe = safeDisplayText(value), !safe.isEmpty else { return }
        attributes.append(StorageHealthAttribute(key: key, label: label, value: .text(safe)))
    }

    private static func sourceHealthFindings(
        state: StorageHealthState,
        status: String?,
        source: StorageHealthSource
    ) -> [StorageHealthFinding] {
        guard state == .warning || state == .failing else { return [] }
        return [StorageHealthFinding(
            kind: .sourceReportedHealth(safeDisplayText(status ?? "") ?? "Reported unhealthy"),
            severity: state == .failing ? .critical : .warning,
            source: source
        )]
    }

    private static func appendUnique(
        _ finding: StorageHealthFinding,
        to findings: inout [StorageHealthFinding]
    ) {
        guard !findings.contains(where: { $0.id == finding.id }) else { return }
        findings.append(finding)
    }

    private static func normalizedFindings(
        _ findings: [StorageHealthFinding]
    ) -> [StorageHealthFinding] {
        var byID: [String: StorageHealthFinding] = [:]
        for finding in findings where byID[finding.id] == nil {
            byID[finding.id] = finding
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func isRedundantOrMisleadingATAAttribute(id: UInt64, name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "")
        // These vendor-specific raw fields are commonly packed values. Their
        // normalized counterparts already live in `StorageHealthMetrics`.
        return id == 190 || id == 194 || normalized.contains("temperature")
    }

    private static func humanizedATAName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeDisplayText(_ value: String) -> String? {
        let scalars = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(160))
    }

    private static func normalizedAttributes(_ attributes: [StorageHealthAttribute]) -> [StorageHealthAttribute] {
        var byKey: [String: StorageHealthAttribute] = [:]
        for attribute in attributes where byKey[attribute.key] == nil {
            byKey[attribute.key] = attribute
        }
        return byKey.values.sorted { $0.key < $1.key }
    }

    private static func trailingByte(in line: String) -> UInt8? {
        if let range = line.range(of: "0x", options: [.caseInsensitive, .backwards]) {
            let suffix = line[range.upperBound...].prefix { $0.isHexDigit }
            if !suffix.isEmpty, let value = UInt8(suffix, radix: 16) {
                return value
            }
        }
        let lastToken = line.components(separatedBy: .whitespacesAndNewlines).last ?? ""
        return UInt8(lastToken.trimmingCharacters(in: .punctuationCharacters))
    }
}
