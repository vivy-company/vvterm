import XCTest
@testable import VVTerm

final class DarwinStatsCollectorParserTests: XCTestCase {
    func testDarwinPeriodicCommandsRunThroughPOSIXShellInsteadOfLoginFish() {
        for command in [
            DarwinStatsCollector.statsBatchCommand,
            DarwinStatsCollector.topCommand,
            DarwinStatsCollector.dfCommand,
            DarwinStatsCollector.diskutilListCommand
        ] {
            XCTAssertTrue(command.hasPrefix("/bin/sh -lc "))
            XCTAssertTrue(command.contains("export LC_ALL=C LANG=C"))
            XCTAssertFalse(command.hasPrefix("LC_ALL=C LANG=C"))
        }
    }

    func testDarwinDisplayJSONParsesGPUWithoutDisplayRows() {
        let output = """
        {
          "SPDisplaysDataType" : [
            {
              "_name" : "Apple M1 Pro",
              "spdisplays_vendor" : "sppci_vendor_Apple",
              "sppci_cores" : "16",
              "sppci_device_type" : "spdisplays_gpu",
              "sppci_model" : "Apple M1 Pro",
              "spdisplays_ndrvs" : [
                { "_name" : "Color LCD", "_spdisplays_pixels" : "3024 x 1964" }
              ]
            }
          ]
        }
        """

        let devices = DarwinStatsCollector().parseDisplayProfileJSON(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Apple M1 Pro")
        XCTAssertEqual(devices.first?.vendor, "Apple")
        XCTAssertEqual(devices.first?.kind, .apple)
    }

    func testDarwinDisplayTextDoesNotTreatDisplaysAsGPUs() {
        let output = """
        Graphics/Displays:

            Apple M1 Pro:

              Chipset Model: Apple M1 Pro
              Type: GPU
              Total Number of Cores: 16
              Vendor: Apple (0x106b)
              Displays:
                Color LCD:
                  Resolution: 3024 x 1964 Retina
        """

        let devices = DarwinStatsCollector().parseDisplayProfile(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Apple M1 Pro")
        XCTAssertEqual(devices.first?.vendor, "Apple (0x106b)")
    }

    func testDarwinProcessParserHandlesNoHeaderFullProcessRows() {
        let output = """
          123 root 12.5 1.2 /usr/bin/python python server.py
          456 uy 1.0 0.4 /bin/zsh -zsh
        """

        let processes = DarwinStatsCollector().parsePs(output)

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, 123)
        XCTAssertEqual(processes[0].user, "root")
        XCTAssertEqual(processes[0].name, "/usr/bin/python")
        XCTAssertEqual(processes[0].command, "python server.py")
    }

    func testDarwinTopCPUParserHandlesCPUUsageLine() {
        let cpu = DarwinStatsCollector().parseTopCpu("CPU usage: 12.34% user, 5.66% sys, 82.00% idle")

        XCTAssertEqual(cpu.user, 12.34, accuracy: 0.001)
        XCTAssertEqual(cpu.system, 5.66, accuracy: 0.001)
        XCTAssertEqual(cpu.idle, 82.0, accuracy: 0.001)
    }

    func testDarwinProcessorLoadParserCalculatesPerCoreUsage() {
        let previous = """
        0 100 50 850 0
        1 200 100 700 0
        """
        let current = """
        0 140 70 890 0
        1 220 130 750 0
        """
        let collector = DarwinStatsCollector()
        let previousValues = collector.parseProcessorLoadOutput(previous, previousValues: [:]).newValues

        let parsed = collector.parseProcessorLoadOutput(current, previousValues: previousValues)

        XCTAssertEqual(parsed.samples.count, 2)
        XCTAssertEqual(parsed.samples[0].displayName, "CPU 1")
        XCTAssertEqual(parsed.samples[0].usagePercent, 60, accuracy: 0.001)
        XCTAssertEqual(parsed.samples[1].usagePercent, 50, accuracy: 0.001)
    }

    func testDarwinVolumeParserPreservesDiskutilIdentityForSyntheticRoot() {
        let diskutil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>AllDisksAndPartitions</key>
          <array>
            <dict>
              <key>DeviceIdentifier</key><string>disk3s5</string>
              <key>VolumeUUID</key><string>01234567-89AB-CDEF-0123-456789ABCDEF</string>
              <key>Content</key><string>Apple_APFS</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
        let collector = DarwinStatsCollector()
        let metadata = collector.parseDiskutilVolumeMetadata(diskutil)
        let volumes = collector.parseDf(
            "/dev/disk3s5 1000 400 600 40% 100 200 33% /System/Volumes/Data",
            metadataBySource: metadata
        )

        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes[0].mountPoint, "/")
        XCTAssertEqual(volumes[0].source, "/dev/disk3s5")
        XCTAssertEqual(volumes[0].fileSystem, "Apple_APFS")
        XCTAssertEqual(
            volumes[0].identity,
            .stable(
                platform: .darwin,
                fileSystemID: "01234567-89ab-cdef-0123-456789abcdef",
                mountPoint: "/"
            )
        )
    }

    func testDarwinDiskutilInfoAcceptsAPFSVolumeGroupIdentity() {
        let diskutilInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>DeviceIdentifier</key><string>disk3s1s1</string>
          <key>APFSVolumeGroupID</key><string>AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE</string>
          <key>FilesystemType</key><string>apfs</string>
        </dict>
        </plist>
        """

        let metadata = DarwinStatsCollector().parseDiskutilVolumeMetadata(diskutilInfo)

        XCTAssertEqual(
            metadata["/dev/disk3s1s1"],
            VolumeCollectionMetadata(
                stableIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                fileSystem: "apfs"
            )
        )
    }

}

