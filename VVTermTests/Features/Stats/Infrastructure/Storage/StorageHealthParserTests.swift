import XCTest
@testable import VVTerm

final class StorageHealthParserTests: XCTestCase {
    private let deviceID = StorageDeviceIdentity(namespace: "test", opaqueValue: "device-1")

    func testSmartctlATAParserNormalizesHealthAndOmitsSensitiveMetadata() throws {
        let output = #"""
        {
          "smartctl": {"exit_status": 0},
          "device": {"name": "/dev/sda", "protocol": "ATA"},
          "model_name": "Example SSD",
          "serial_number": "SECRET-SERIAL",
          "firmware_version": "1.2.3",
          "smart_status": {"passed": true},
          "temperature": {"current": 36},
          "power_on_time": {"hours": 1234},
          "power_cycle_count": 42,
          "ata_smart_attributes": {
            "table": [
              {"id": 5, "name": "Reallocated_Sector_Ct", "when_failed": "-", "raw": {"value": 3}},
              {"id": 197, "name": "Current_Pending_Sector", "when_failed": "FAILING_NOW", "raw": {"value": 1}}
            ]
          }
        }
        """#

        let report = try report(from: StorageHealthParser.parseSmartctlJSON(output, deviceID: deviceID))

        XCTAssertEqual(report.state, .warning)
        XCTAssertEqual(report.metrics.temperatureCelsius, 36)
        XCTAssertEqual(report.metrics.powerOnHours, 1_234)
        XCTAssertEqual(report.metrics.powerCycleCount, 42)
        XCTAssertEqual(report.sources, [.smartctl])
        XCTAssertTrue(report.attributes.contains { $0.key == "smart.ata.5" })
        XCTAssertTrue(report.attributes.contains { $0.key == "device.model" })
        XCTAssertFalse(report.attributes.contains { $0.key.localizedCaseInsensitiveContains("serial") })
        XCTAssertFalse(report.attributes.contains { attribute in
            if case .text(let value) = attribute.value {
                return value.contains("SECRET-SERIAL") || value.contains("/dev/sda")
            }
            return false
        })
    }

    func testSmartctlNVMeParserHandlesWarningMetricsAndOverflowSafely() throws {
        let output = #"""
        {
          "smartctl": {"exit_status": 16},
          "smart_status": {"passed": true},
          "nvme_smart_health_information_log": {
            "critical_warning": 1,
            "temperature": 41,
            "available_spare": 98,
            "available_spare_threshold": 10,
            "percentage_used": 7,
            "power_on_hours": 18446744073709551616,
            "power_cycles": 99,
            "unsafe_shutdowns": 2,
            "media_errors": 1,
            "num_err_log_entries": 5
          }
        }
        """#

        let report = try report(from: StorageHealthParser.parseSmartctlJSON(output, deviceID: deviceID))

        XCTAssertEqual(report.state, .warning)
        XCTAssertEqual(report.metrics.temperatureCelsius, 41)
        XCTAssertEqual(report.metrics.percentageUsed, 7)
        XCTAssertEqual(report.metrics.availableSparePercent, 98)
        XCTAssertNil(report.metrics.powerOnHours)
        XCTAssertEqual(report.metrics.powerCycleCount, 99)
        XCTAssertEqual(report.metrics.mediaErrorCount, 1)
        XCTAssertFalse(report.findings.contains {
            if case .scsiErrorHistory = $0.kind { return true }
            return false
        })
    }

    func testSmartctlExitBitsAreClassifiedIndependently() throws {
        let cases: [(UInt64, StorageHealthFindingKind, StorageHealthFindingTiming, StorageHealthState)] = [
            (0x10, .smartCurrentPrefailThreshold, .current, .warning),
            (0x20, .smartPastThreshold, .historical, .healthy),
            (0x40, .smartErrorLog, .historical, .healthy),
            (0x80, .smartSelfTestLog, .historical, .healthy)
        ]

        for (exitStatus, kind, timing, expectedState) in cases {
            let output = #"{"smartctl":{"exit_status":\#(exitStatus)},"smart_status":{"passed":true}}"#
            let report = try report(from: StorageHealthParser.parseSmartctlJSON(output, deviceID: deviceID))
            let finding = try XCTUnwrap(report.findings.first { $0.kind == kind })
            XCTAssertEqual(finding.timing, timing)
            XCTAssertEqual(report.state, expectedState)
        }
    }

    func testPackedATATemperatureRawValueIsNotPresentedAsAnotherTemperature() throws {
        let output = #"""
        {
          "smartctl": {"exit_status": 0},
          "smart_status": {"passed": true},
          "temperature": {"current": 32},
          "ata_smart_attributes": {"table": [
            {"id": 194, "name": "Temperature_Celsius", "when_failed": "-", "raw": {"value": 253403070496}}
          ]}
        }
        """#

        let report = try report(from: StorageHealthParser.parseSmartctlJSON(output, deviceID: deviceID))

        XCTAssertEqual(report.metrics.temperatureCelsius, 32)
        XCTAssertFalse(report.attributes.contains { $0.key == "smart.ata.194" })
    }

    func testSmartctlSCSIParserNormalizesErrorCounters() throws {
        let output = #"""
        {
          "smartctl": {"exit_status": 0},
          "smart_status": {"passed": true},
          "scsi_temperature": {"current": 28, "drive_trip": 65},
          "scsi_start_stop_cycle_counter": {
            "accumulated_start_stop_cycles": 80,
            "accumulated_load_unload_cycles": 224
          },
          "scsi_grown_defect_list": 4,
          "scsi_error_counter_log": {
            "read": {"total_errors_corrected": 9, "total_uncorrected_errors": 1},
            "write": {"total_errors_corrected": 7, "total_uncorrected_errors": 2}
          }
        }
        """#

        let report = try report(from: StorageHealthParser.parseSmartctlJSON(output, deviceID: deviceID))

        XCTAssertEqual(report.metrics.temperatureCelsius, 28)
        XCTAssertEqual(report.metrics.maximumTemperatureCelsius, 65)
        XCTAssertEqual(report.metrics.startStopCycleCount, 80)
        XCTAssertEqual(report.metrics.loadUnloadCycleCount, 224)
        XCTAssertEqual(report.metrics.mediaErrorCount, 4)
        XCTAssertEqual(report.metrics.readErrorsUncorrected, 1)
        XCTAssertEqual(report.metrics.writeErrorsUncorrected, 2)
        XCTAssertTrue(report.findings.contains {
            $0.kind == .scsiErrorHistory(read: 1, write: 2, media: 4)
                && $0.timing == .historical
                && $0.severity == .information
        })
        XCTAssertEqual(report.state, .healthy)
    }

    func testSmartctlPermissionFailureIsCapabilityState() {
        let output = #"""
        {
          "smartctl": {
            "exit_status": 2,
            "messages": [{"severity": "error", "string": "Permission denied opening device"}]
          }
        }
        """#

        XCTAssertEqual(
            StorageHealthParser.parseSmartctlJSON(output, deviceID: deviceID),
            .unavailable(.permissionDenied)
        )
    }

    func testSmartctlMalformedAndUnknownValuesDoNotTrap() {
        XCTAssertEqual(
            StorageHealthParser.parseSmartctlJSON("{not-json", deviceID: deviceID),
            .unavailable(.invalidResponse)
        )
        XCTAssertEqual(
            StorageHealthParser.parseSmartctlJSON("smartctl: command not found", deviceID: deviceID),
            .unavailable(.toolMissing)
        )
    }

    func testEMMCParserKeepsJEDECBucketSemantics() throws {
        let output = """
        eMMC Pre EOL information [EXT_CSD_PRE_EOL_INFO]: 0x02
        eMMC Life Time Estimation A [EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_A]: 0x0A
        eMMC Life Time Estimation B [EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_B]: 0x0B
        """

        let report = try report(from: StorageHealthParser.parseEMMCExtCSD(output, deviceID: deviceID))
        let emmc = try XCTUnwrap(report.metrics.emmc)

        XCTAssertEqual(report.state, .warning)
        XCTAssertEqual(emmc.preEOL, .warning)
        XCTAssertEqual(
            emmc.lifetimeTypeA?.bucket,
            .estimatedUsage(lowerPercent: 90, upperPercent: 100)
        )
        XCTAssertEqual(emmc.lifetimeTypeB?.bucket, .exceededMaximumEstimate)
    }

    func testEMMCParserPreservesUnknownAndReservedBuckets() throws {
        let output = """
        PRE_EOL_INFO: 0x00
        DEVICE_LIFE_TIME_EST_TYP_A: 0x00
        DEVICE_LIFE_TIME_EST_TYP_B: 0xFE
        """

        let report = try report(from: StorageHealthParser.parseEMMCExtCSD(output, deviceID: deviceID))
        let emmc = try XCTUnwrap(report.metrics.emmc)

        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(emmc.lifetimeTypeA?.bucket, .unknown)
        XCTAssertEqual(emmc.lifetimeTypeB?.bucket, .reserved(0xFE))
    }

    func testDarwinPlistParserNormalizesNativeSMARTAndDoesNotExposeIdentifiers() throws {
        let plist: [String: Any] = [
            "DeviceNode": "/dev/disk0",
            "DeviceIdentifier": "disk0",
            "MediaName": "APPLE SSD",
            "BusProtocol": "Apple Fabric",
            "SerialNumber": "SECRET-SERIAL",
            "SolidState": true,
            "Internal": true,
            "VirtualOrPhysical": "Physical",
            "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "TEMPERATURE": 315,
                "PERCENTAGE_USED": 7,
                "AVAILABLE_SPARE": 100,
                "AVAILABLE_SPARE_THRESHOLD": 99,
                "POWER_ON_HOURS_0": 1,
                "POWER_ON_HOURS_1": 1,
                "MEDIA_ERRORS_0": 0,
                "MEDIA_ERRORS_1": 0
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let report = try report(from: StorageHealthParser.parseDarwinPlist(data, deviceID: deviceID))

        XCTAssertEqual(report.state, .healthy)
        XCTAssertEqual(report.metrics.temperatureCelsius ?? 0, 41.85, accuracy: 0.001)
        XCTAssertEqual(report.metrics.percentageUsed, 7)
        XCTAssertNil(report.metrics.powerOnHours)
        XCTAssertTrue(report.attributes.contains { $0.key == "darwin.power_on_hours" })
        XCTAssertFalse(report.attributes.contains { attribute in
            attribute.key.localizedCaseInsensitiveContains("serial")
                || attribute.key.localizedCaseInsensitiveContains("path")
                || (attribute.value == .text("SECRET-SERIAL"))
                || (attribute.value == .text("/dev/disk0"))
        })
    }

    func testDarwinPlistPartialMetadataRemainsNonAlarming() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["MediaName": "USB Bridge", "SMARTStatus": "Not Supported"],
            format: .xml,
            options: 0
        )

        let report = try report(from: StorageHealthParser.parseDarwinPlist(data, deviceID: deviceID))

        XCTAssertEqual(report.state, .unknown)
        XCTAssertTrue(report.attributes.contains { $0.key == "device.model" })
    }

    func testWindowsNativeParserNormalizesHealthAndIgnoresSerialAndPaths() throws {
        let output = #"""
        {
          "FriendlyName": "Example NVMe",
          "BusType": "NVMe",
          "HealthStatus": "Healthy",
          "OperationalStatus": ["OK"],
          "PhysicalHealthStatus": "Warning",
          "PhysicalOperationalStatus": ["Predictive Failure"],
          "Temperature": 43,
          "TemperatureMax": 70,
          "Wear": 12,
          "PowerOnHours": 500,
          "ReadErrorsCorrected": 3,
          "ReadErrorsUncorrected": 1,
          "WriteErrorsCorrected": 4,
          "WriteErrorsUncorrected": 0,
          "StartStopCycleCount": 5,
          "LoadUnloadCycleCount": 6,
          "SerialNumber": "SECRET-SERIAL",
          "Path": "\\\\?\\scsi#disk"
        }
        """#

        let report = try report(from: StorageHealthParser.parseWindowsNativeJSON(output, deviceID: deviceID))

        XCTAssertEqual(report.state, .warning)
        XCTAssertEqual(report.metrics.temperatureCelsius, 43)
        XCTAssertEqual(report.metrics.percentageUsed, 12)
        XCTAssertEqual(report.metrics.readErrorsUncorrected, 1)
        XCTAssertFalse(report.attributes.contains { attribute in
            attribute.key.localizedCaseInsensitiveContains("serial")
                || attribute.key.localizedCaseInsensitiveContains("path")
                || attribute.value == .text("SECRET-SERIAL")
        })
    }

    func testWindowsProbePermissionFailureIsTyped() {
        XCTAssertEqual(
            StorageHealthParser.parseWindowsNativeJSON(
                #"{"ProbeError":"Access is denied"}"#,
                deviceID: deviceID
            ),
            .unavailable(.permissionDenied)
        )
    }

    func testBSDMetadataParserWhitelistsDisplayFields() throws {
        let output = """
        Geom name: ada0
        Name: /dev/ada0
        Mediasize: 1000204886016 (932G)
        Sectorsize: 512
        descr: Example SSD
        ident: SECRET-SERIAL
        duid: SECRET-DUID
        rotationrate: 0
        """

        let report = try report(from: StorageHealthParser.parseBSDMetadata(output, deviceID: deviceID))

        XCTAssertEqual(report.state, .unknown)
        XCTAssertTrue(report.attributes.contains { $0.key == "device.model" })
        XCTAssertTrue(report.attributes.contains { $0.key == "device.media_size" })
        XCTAssertFalse(report.attributes.contains { attribute in
            attribute.key.contains("ident")
                || attribute.key.contains("duid")
                || attribute.value == .text("SECRET-SERIAL")
                || attribute.value == .text("SECRET-DUID")
                || attribute.value == .text("/dev/ada0")
        })
    }

    func testMergedReportUsesWorstStateAndCompletesMissingMetrics() throws {
        var nativeMetrics = StorageHealthMetrics()
        nativeMetrics.temperatureCelsius = 35
        let native = StorageHealthReport(
            deviceID: deviceID,
            state: .healthy,
            metrics: nativeMetrics,
            sources: [.windowsStorage]
        )
        var smartMetrics = StorageHealthMetrics()
        smartMetrics.percentageUsed = 8
        let smart = StorageHealthReport(
            deviceID: deviceID,
            state: .warning,
            metrics: smartMetrics,
            sources: [.smartctl]
        )

        let report = try report(from: StorageHealthParser.merged([.report(native), .report(smart)]))

        XCTAssertEqual(report.state, .warning)
        XCTAssertEqual(report.metrics.temperatureCelsius, 35)
        XCTAssertEqual(report.metrics.percentageUsed, 8)
        XCTAssertEqual(report.sources, [.windowsStorage, .smartctl])
    }

    func testReadOnlyProbeCommandsQuotePathsAndContainNoMutatingOperations() {
        let linux = StorageHealthProbe.linuxCommand(
            devicePath: "/dev/disk'quoted",
            isEMMC: true
        )
        XCTAssertTrue(linux.contains("/dev/disk"))
        XCTAssertTrue(linux.contains("quoted"))
        XCTAssertFalse(linux.contains("/dev/disk'quoted"))
        assertReadOnlyProbe(linux)

        let darwin = StorageHealthProbe.darwinCommand(
            nativeIdentifier: "/Volumes/O'Brien",
            smartctlDevicePath: "/dev/disk9"
        )
        XCTAssertTrue(darwin.contains("/Volumes/O"))
        XCTAssertTrue(darwin.contains("Brien"))
        XCTAssertFalse(darwin.contains("/Volumes/O'Brien"))
        assertReadOnlyProbe(darwin)

        for platform in [
            StorageHealthProbe.BSDPlatform.freeBSD,
            .openBSD,
            .netBSD
        ] {
            assertReadOnlyProbe(StorageHealthProbe.bsdCommand(
                platform: platform,
                devicePath: "/dev/disk'quoted"
            ))
        }

        let windows = StorageHealthProbe.windowsScript(diskNumber: UInt32.max)
        XCTAssertTrue(windows.contains("Get-StorageReliabilityCounter -Disk $disk"))
        XCTAssertTrue(windows.contains("Get-PhysicalDisk"))
        XCTAssertFalse(windows.localizedCaseInsensitiveContains("SerialNumber"))
        assertReadOnlyProbe(windows)
    }

    func testCapabilityMirrorsResultState() {
        XCTAssertEqual(
            StorageDeviceHealthResult.unavailable(.networkVolume).capability,
            .unavailable(.networkVolume)
        )
        XCTAssertEqual(
            StorageDeviceHealthResult.report(StorageHealthReport(
                deviceID: deviceID,
                sources: [.smartctl]
            )).capability,
            .supported
        )
    }

    private func report(
        from result: StorageDeviceHealthResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> StorageHealthReport {
        guard case .report(let report) = result else {
            XCTFail("Expected health report, got \(result)", file: file, line: line)
            throw TestError.expectedReport
        }
        return report
    }

    private func assertReadOnlyProbe(
        _ command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lowercased = command.lowercased()
        XCTAssertFalse(lowercased.contains("sudo"), file: file, line: line)
        XCTAssertFalse(lowercased.contains("smartctl -t"), file: file, line: line)
        XCTAssertFalse(lowercased.contains("reset-storagereliabilitycounter"), file: file, line: line)
        XCTAssertFalse(lowercased.contains("start-storage"), file: file, line: line)
        XCTAssertFalse(lowercased.contains("format-volume"), file: file, line: line)
        XCTAssertFalse(lowercased.contains("clear-disk"), file: file, line: line)
    }

    private enum TestError: Error {
        case expectedReport
    }
}
