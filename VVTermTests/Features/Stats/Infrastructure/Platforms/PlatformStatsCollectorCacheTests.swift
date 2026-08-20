import XCTest
@testable import VVTerm

final class PlatformStatsCollectorCacheTests: XCTestCase {
    func testProcessCPUPercentagesUseTotalMachineCapacityOverSampleInterval() {
        let context = StatsCollectionContext()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(context.processCPUPercentages(
            cumulativeCPUTimeByPID: [42: 10],
            timestamp: start,
            logicalProcessorCount: 8
        ).isEmpty)

        let percentages = context.processCPUPercentages(
            cumulativeCPUTimeByPID: [42: 12],
            timestamp: start.addingTimeInterval(2),
            logicalProcessorCount: 8
        )

        XCTAssertEqual(percentages[42] ?? -1, 12.5, accuracy: 0.001)
    }

    func testPeriodicProcessCachePreservesLastGoodSample() {
        let context = StatsCollectionContext()
        let process = ProcessInfo(pid: 42, name: "worker", cpuPercent: 25, memoryPercent: 5)

        context.updatePeriodicProcesses([process], timestamp: Date(timeIntervalSince1970: 100))
        context.updatePeriodicProcesses([], timestamp: Date(timeIntervalSince1970: 105))

        XCTAssertEqual(context.getPeriodicProcesses().map(\.pid), [42])
        XCTAssertFalse(context.shouldCollectPeriodicProcesses(
            now: Date(timeIntervalSince1970: 106),
            minimumInterval: 5
        ))
    }

    func testVolumeMetadataCacheClaimsRefreshWindowAndResets() {
        let context = StatsCollectionContext()
        let start = Date(timeIntervalSince1970: 100)
        let metadata = VolumeCollectionMetadata(stableIdentifier: "disk-id", fileSystem: "ext4")

        XCTAssertTrue(context.beginVolumeMetadataRefresh(for: .linux, now: start))
        XCTAssertFalse(context.beginVolumeMetadataRefresh(
            for: .linux,
            now: start.addingTimeInterval(10)
        ))
        context.updateVolumeMetadata(["/dev/sda1": metadata], for: .linux)
        XCTAssertEqual(context.volumeMetadata(for: .linux)["/dev/sda1"], metadata)

        context.reset()

        XCTAssertTrue(context.volumeMetadata(for: .linux).isEmpty)
        XCTAssertTrue(context.beginVolumeMetadataRefresh(
            for: .linux,
            now: start.addingTimeInterval(10)
        ))
    }

    func testUnixProcessParserUsesResidentBytesAndIntervalCPU() {
        let output = """
          1124 root 0:12.50 87.4 262144 python server.py
          2048 uy 1:02.25 12.0 524288 ollama serve
        """

        let rows = UnixProcessTelemetry.parseProcessRows(output)
        let processes = UnixProcessTelemetry.makeProcesses(
            from: rows,
            intervalCPUPercentages: [1124: 25],
            memoryTotal: 4_294_967_296
        )

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].cpuPercent, 25, accuracy: 0.001)
        XCTAssertEqual(processes[0].memoryBytes, 268_435_456)
        XCTAssertEqual(processes[0].memoryPercent, 6.25, accuracy: 0.001)
        XCTAssertEqual(processes[0].command, "python server.py")
    }

    func testUnixProcessCommandsForceInvariantLocale() {
        XCTAssertTrue(UnixProcessTelemetry.processDetailsCommand(
            platform: .darwin,
            limit: 24,
            pids: nil
        ).contains("LC_ALL=C LANG=C"))
        XCTAssertTrue(UnixProcessTelemetry.processDetailsCommand(
            platform: .linux,
            limit: nil,
            pids: nil
        ).contains("LC_ALL=C LANG=C"))
    }

    func testBSDPeriodicProcessCommandsAreSortedAndOnDemandIsUnbounded() {
        for platform in [RemotePlatform.freebsd, .openbsd, .netbsd] {
            let periodic = UnixProcessTelemetry.processDetailsCommand(
                platform: platform,
                limit: 24,
                pids: nil
            )
            XCTAssertTrue(periodic.contains("sort -k4 -nr"))
            XCTAssertTrue(periodic.contains("head -n 24"))

            let full = UnixProcessTelemetry.processDetailsCommand(
                platform: platform,
                limit: nil,
                pids: nil
            )
            XCTAssertFalse(full.contains("head -n"))
        }
    }

    func testUnixCPUTimeParserHandlesDaysAndFractionalSeconds() {
        XCTAssertEqual(UnixProcessTelemetry.parseCPUTime("1-02:03:04.50") ?? -1, 93_784.5, accuracy: 0.001)
        XCTAssertEqual(UnixProcessTelemetry.parseCPUTime("12:34.25") ?? -1, 754.25, accuracy: 0.001)
    }

}

