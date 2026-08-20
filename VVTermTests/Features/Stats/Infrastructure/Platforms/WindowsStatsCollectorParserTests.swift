import XCTest
@testable import VVTerm

final class WindowsStatsCollectorParserTests: XCTestCase {
    func testWindowsGPUParserFiltersVirtualAdaptersAndAvoidsCappedVRAM() {
        let output = """
        GameViewer Virtual Display Adapter|GameViewer|0|1.0|ROOT\\DISPLAY\\0000|OK
        SudoMaker Virtual Display Adapter|SudoMaker|0|1.0|ROOT\\DISPLAY\\0001|OK
        NVIDIA GeForce RTX 3060|NVIDIA|4293918720|555.42|PCI\\VEN_10DE&DEV_2504|OK
        Intel UHD Graphics|Intel Corporation|1073741824|31.0|PCI\\VEN_8086&DEV_9A49|OK
        """

        let devices = WindowsStatsCollector().parseWindowsGPUs(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].kind, .nvidia)
        XCTAssertEqual(devices[0].memoryTotal, 0)
        XCTAssertEqual(devices[1].kind, .intel)
        XCTAssertEqual(devices[1].memoryTotal, 1_073_741_824)
    }

    func testWindowsNvidiaParserUsesSMIForRealVRAM() {
        let output = "0, NVIDIA GeForce RTX 3060, GPU-abc, 45, 2048, 12288, 63, 120.5, 555.42"

        let devices = WindowsStatsCollector().parseWindowsNvidiaGPUs(output)
        let samples = WindowsStatsCollector().parseWindowsNvidiaSamples(
            output,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "nvidia-0")
        XCTAssertEqual(devices[0].memoryTotal, 12_288 * 1_048_576)
        XCTAssertEqual(samples[0].utilizationPercent, 45)
        XCTAssertEqual(samples[0].memoryUsed, 2_048 * 1_048_576)
        XCTAssertEqual(samples[0].memoryTotal, 12_288 * 1_048_576)
    }

    func testWindowsGPUCounterParserReadsPerfRows() {
        let samples = WindowsStatsCollector().parseWindowsGPUCounterSamples(
            "PERF|windows-phys-0|125.4|2147483648|8589934592",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].deviceID, "windows-phys-0")
        XCTAssertEqual(samples[0].utilizationPercent, 100)
        XCTAssertEqual(samples[0].memoryUsed, 2_147_483_648)
        XCTAssertEqual(samples[0].memoryTotal, 8_589_934_592)
    }

    func testWindowsGPUCounterParserTreatsZeroMemoryLimitAsMissing() {
        let samples = WindowsStatsCollector().parseWindowsGPUCounterSamples(
            "PERF|windows-phys-0|25.0|2147483648|0",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].deviceID, "windows-phys-0")
        XCTAssertEqual(samples[0].utilizationPercent, 25)
        XCTAssertEqual(samples[0].memoryUsed, 2_147_483_648)
        XCTAssertNil(samples[0].memoryTotal)
    }

    func testWindowsCPUParserReadsPerCoreCounters() {
        let output = """
        TOTAL|24.5|18.0|6.5
        CORE|0|12.0|8.0|4.0
        CORE|1|88.5|70.0|18.5
        """

        let usage = WindowsStatsCollector().parseWindowsCPUUsage(output)

        XCTAssertEqual(usage.usagePercent, 24.5)
        XCTAssertEqual(usage.userPercent, 18.0)
        XCTAssertEqual(usage.systemPercent, 6.5)
        XCTAssertEqual(usage.coreSamples.count, 2)
        XCTAssertEqual(usage.coreSamples[1].displayName, "CPU 2")
        XCTAssertEqual(usage.coreSamples[1].usagePercent, 88.5)
    }

    func testWindowsCPUParserReadsLocalizedDecimalCommas() {
        let output = """
        TOTAL|24,5|18,0|6,5
        CORE|0|12,0|8,0|4,0
        CORE|1|88,5|70,0|18,5
        """

        let usage = WindowsStatsCollector().parseWindowsCPUUsage(output)

        XCTAssertEqual(usage.usagePercent, 24.5)
        XCTAssertEqual(usage.userPercent, 18.0)
        XCTAssertEqual(usage.systemPercent, 6.5)
        XCTAssertEqual(usage.coreSamples.count, 2)
        XCTAssertEqual(usage.coreSamples[1].usagePercent, 88.5)
        XCTAssertEqual(usage.coreSamples[1].systemPercent, 18.5)
    }

    func testWindowsPeriodicStatsParserReadsOneBatchedResponse() {
        let output = """
        MEMORY|17179869184|10737418240|6442450944
        UPTIME|86400
        PROCESS_COUNT|137
        NETWORK|123456789|987654321
        """

        let collector = WindowsStatsCollector()
        let snapshot = collector.parsePeriodicStats(output)

        XCTAssertEqual(snapshot.memory?.total, 17_179_869_184)
        XCTAssertEqual(snapshot.memory?.used, 10_737_418_240)
        XCTAssertEqual(snapshot.memory?.free, 6_442_450_944)
        XCTAssertEqual(snapshot.uptime, 86_400)
        XCTAssertEqual(snapshot.processCount, 137)
        XCTAssertEqual(snapshot.network?.rx, 123_456_789)
        XCTAssertEqual(snapshot.network?.tx, 987_654_321)
    }

    func testWindowsPeriodicStatsParserKeepsValidSectionsWhenOneSectionIsMalformed() {
        let snapshot = WindowsStatsCollector().parsePeriodicStats(
            """
            MEMORY|invalid|20|30
            UPTIME|42
            PROCESS_COUNT|-1
            NETWORK|18446744073709551615|9
            """
        )

        XCTAssertNil(snapshot.memory)
        XCTAssertEqual(snapshot.uptime, 42)
        XCTAssertNil(snapshot.processCount)
        XCTAssertEqual(snapshot.network?.rx, UInt64.max)
        XCTAssertEqual(snapshot.network?.tx, 9)
    }

    func testWindowsPeriodicStatsScriptContainsAllCoreMetricsInOneScript() {
        let script = WindowsStatsCollector().periodicStatsPowerShellScript()

        XCTAssertFalse(script.contains("__VVTERM_CPU_BEGIN__"))
        XCTAssertTrue(script.contains("MEMORY|"))
        XCTAssertTrue(script.contains("UPTIME|"))
        XCTAssertTrue(script.contains("PROCESS_COUNT|"))
        XCTAssertTrue(script.contains("NETWORK|"))
    }

    func testWindowsPeriodicStatsCommandFitsCmdCommandLineLimit() {
        let script = WindowsStatsCollector().periodicStatsPowerShellScript()
        let powerShell = RemoteTerminalBootstrap.wrapPowerShellCommand(
            script,
            executableName: "powershell"
        )
        let command = RemoteTerminalBootstrap.wrapCmdExecCommand(powerShell)

        XCTAssertLessThan(command.utf16.count, 8_191)
    }

    func testWindowsProcessParserReturnsAllRows() {
        let output = """
        10|System|100.0|50.0|2147483648
        20|Terminal|12.5|20.0|858993459
        30|Code|2.0|12.5|536870912
        """

        let processes = WindowsStatsCollector().parseProcesses(output)

        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[1].name, "Terminal")
        XCTAssertEqual(processes[1].memoryBytes, 858_993_459)
    }

    func testWindowsWMICProcessParserNormalizesCPUAndMemoryPercent() {
        let output = """
        Node,IDProcess,Name,PercentProcessorTime,WorkingSet
        HOST,100,python,320,1073741824
        HOST,200,code,40,536870912
        """

        let processes = WindowsStatsCollector().parseWMICProcesses(
            output,
            memoryTotal: 4_294_967_296,
            logicalProcessorCount: 8
        )

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].cpuPercent, 40)
        XCTAssertEqual(processes[0].memoryPercent, 25)
        XCTAssertEqual(processes[1].cpuPercent, 5)
        XCTAssertEqual(processes[1].memoryPercent, 12.5)
    }

    func testWindowsWMICProcessParserReadsLocalizedDecimalCommaCPU() {
        let output = """
        Node,IDProcess,Name,PercentProcessorTime,WorkingSet
        HOST,100,python,"320,0",1073741824
        """

        let processes = WindowsStatsCollector().parseWMICProcesses(
            output,
            memoryTotal: 4_294_967_296,
            logicalProcessorCount: 8
        )

        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].cpuPercent, 40)
    }

    func testWindowsWMICVolumeParserHandlesDriveRows() {
        let output = """
        Caption=C:
        FreeSpace=1073741824
        Size=10737418240

        Caption=D:
        FreeSpace=2147483648
        Size=21474836480
        """

        let volumes = WindowsStatsCollector().parseWMICVolumes(output)

        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].mountPoint, "C:\\")
        XCTAssertEqual(volumes[0].used, 9_663_676_416)
    }

    func testWindowsVolumeParserUsesNativeUniqueIDAndFileSystem() {
        let collector = WindowsStatsCollector()
        let metadata = collector.parseWindowsVolumeMetadata(
            "C|NTFS|\\\\?\\Volume{01234567-89AB-CDEF-0123-456789ABCDEF}\\"
        )
        let volumes = collector.parseVolumes(
            "C|9663676416|10737418240",
            metadataByMountPoint: metadata
        )

        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes[0].mountPoint, "C:\\")
        XCTAssertEqual(volumes[0].source, "C:\\")
        XCTAssertEqual(volumes[0].fileSystem, "NTFS")
        XCTAssertEqual(
            volumes[0].identity,
            .stable(
                platform: .windows,
                fileSystemID: "\\\\?\\volume{01234567-89ab-cdef-0123-456789abcdef}\\",
                mountPoint: "C:\\"
            )
        )
    }

    func testWindowsNetstatParserReadsBytesLine() {
        let totals = WindowsStatsCollector().parseNetstatInterfaceStats(
            "Bytes                  123456789      987654321"
        )

        XCTAssertEqual(totals.rx, 123_456_789)
        XCTAssertEqual(totals.tx, 987_654_321)
    }

}

