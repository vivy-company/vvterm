import XCTest
@testable import VVTerm

final class UnixStatsCollectorParserTests: XCTestCase {
    func testLinuxDfParserKeepsFirstDataRowAndOverlayRoot() {
        let output = """
        Filesystem     1M-blocks  Used Available Use% Mounted on
        overlay           100000 70000     30000  70% /
        /dev/sda1         200000 50000    150000  25% /data
        """

        let volumes = LinuxStatsCollector().parseDfVolumes(output)

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].mountPoint, "/")
        XCTAssertEqual(volumes[0].used, 70_000 * 1_048_576)
    }

    func testLinuxDfParserRejectsCapacityBeyondUInt64WithoutTrapping() {
        let output = """
        Filesystem Type Size Used Avail Use% Mounted on
        /dev/sda1 ext4 16384P 1P 16383P 1% /too-large
        """

        XCTAssertTrue(LinuxStatsCollector().parseDfVolumes(output).isEmpty)
    }

    func testLinuxVolumeParserRetainsTypeAndLSBLKStableIdentity() {
        let lsblk = """
        {
          "blockdevices": [
            {
              "name": "/dev/sda",
              "uuid": null,
              "fstype": null,
              "children": [
                {"name": "/dev/sda1", "uuid": "DATA-1234", "fstype": "ext4"}
              ]
            }
          ]
        }
        """
        let df = """
        Filesystem     Type     1M-blocks  Used Available Use% Mounted on
        overlay        overlay      100000 70000     30000  70% /
        /dev/sda1      ext4         200000 50000    150000  25% /data
        """
        let collector = LinuxStatsCollector()
        let metadata = collector.parseLSBLKVolumeMetadata(lsblk)
        let volumes = collector.parseDfVolumes(df, metadataBySource: metadata)

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].source, "overlay")
        XCTAssertEqual(volumes[0].fileSystem, "overlay")
        XCTAssertEqual(volumes[0].kind, .container)
        XCTAssertEqual(volumes[1].source, "/dev/sda1")
        XCTAssertEqual(volumes[1].fileSystem, "ext4")
        XCTAssertEqual(
            volumes[1].identity,
            .stable(platform: .linux, fileSystemID: "data-1234", mountPoint: "/data")
        )
    }

    func testBSDVolumeParsersRetainSourcePlatformAndDoNotCapRows() {
        let freeBSDRows = (0..<12).map { index in
            "/dev/ada0p\(index) ufs 200 50 150 25% /data/\(index)"
        }.joined(separator: "\n")
        let mountMetadata = parseBSDMountVolumeMetadata("""
        /dev/sd0a on / type ffs (local)
        /dev/ada0p0 on /data/0 (ufs, local, soft-updates)
        /dev/dk0 on /srv (ffs, local)
        """)
        let freeBSD = FreeBSDStatsCollector().parseDf(freeBSDRows)
        let openBSD = OpenBSDStatsCollector().parseDf(
            "/dev/sd0a 204800 51200 153600 25% /",
            metadataBySource: mountMetadata
        )
        let netBSD = NetBSDStatsCollector().parseDf(
            "/dev/dk0 204800 51200 153600 25% /srv",
            metadataBySource: mountMetadata
        )

        XCTAssertEqual(freeBSD.count, 12)
        XCTAssertEqual(freeBSD[0].source, "/dev/ada0p0")
        XCTAssertEqual(freeBSD[0].fileSystem, "ufs")
        XCTAssertEqual(mountMetadata["/dev/ada0p0"]?.fileSystem, "ufs")
        XCTAssertEqual(
            freeBSD[0].identity,
            .fallback(
                platform: .freebsd,
                source: "/dev/ada0p0",
                mountPoint: "/data/0",
                fileSystem: "ufs"
            )
        )
        XCTAssertEqual(openBSD.first?.source, "/dev/sd0a")
        XCTAssertEqual(openBSD.first?.fileSystem, "ffs")
        XCTAssertEqual(netBSD.first?.source, "/dev/dk0")
        XCTAssertEqual(netBSD.first?.fileSystem, "ffs")
        if case .some(.fallback(let platform, _, _, _)) = openBSD.first?.identity {
            XCTAssertEqual(platform, .openbsd)
        } else {
            XCTFail("Expected OpenBSD fallback volume identity")
        }
        if case .some(.fallback(let platform, _, _, _)) = netBSD.first?.identity {
            XCTAssertEqual(platform, .netbsd)
        } else {
            XCTFail("Expected NetBSD fallback volume identity")
        }
    }

    func testLinuxProcStatCoreParserCalculatesPerCorePercentages() {
        let previous = """
        cpu  100 0 50 850 0 0 0 0
        cpu0 50 0 25 425 0 0 0 0
        cpu1 50 0 25 425 0 0 0 0
        """
        let current = """
        cpu  140 0 70 890 0 0 0 0
        cpu0 70 0 35 445 0 0 0 0
        cpu1 70 0 35 445 0 0 0 0
        """
        let collector = LinuxStatsCollector()
        let previousValues = collector.parseProcStatCores(previous, prevValues: [:]).newValues

        let result = collector.parseProcStatCores(current, prevValues: previousValues)

        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.samples[0].usagePercent, 60, accuracy: 0.001)
        XCTAssertEqual(result.samples[0].displayName, "CPU 1")
    }

    func testLinuxNvidiaSampleParserNormalizesMemory() {
        let samples = LinuxStatsCollector().parseNvidiaSamples(
            "0, 76, 14336, 24576, 62, 284.5",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].deviceID, "nvidia-0")
        XCTAssertEqual(samples[0].utilizationPercent, 76)
        XCTAssertEqual(samples[0].memoryUsed, 14_336 * 1_048_576)
    }

    func testLinuxProcessParserHandlesFullRows() {
        let output = """
          1124 root 62.4 18.2 python python server.py
          2048 uy 18.0 24.9 ollama ollama serve
        """

        let processes = LinuxStatsCollector().parsePs(output)

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].user, "root")
        XCTAssertEqual(processes[0].command, "python server.py")
    }

    func testLinuxMemoryParserFallsBackWhenMemAvailableIsMissing() {
        let output = """
        MemTotal:       1000000 kB
        MemFree:         100000 kB
        Buffers:          50000 kB
        Cached:          300000 kB
        SReclaimable:     50000 kB
        Shmem:            25000 kB
        """

        let memory = LinuxStatsCollector().parseProcMeminfo(output)

        XCTAssertEqual(memory.used, 525_000 * 1_024)
    }

}

