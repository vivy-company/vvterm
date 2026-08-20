import XCTest
@testable import VVTerm

final class DockerStatsCollectorParserTests: XCTestCase {
    func testDockerParserMergesContainerRowsWithStatsRows() {
        let psOutput = """
        {"ID":"abcdef1234567890","Names":"api","Image":"ghcr.io/app/api:latest","Command":"./api","CreatedAt":"2026-07-06 10:00:00 +0000 UTC","RunningFor":"2 hours ago","Ports":"0.0.0.0:8080->8080/tcp","Status":"Up 2 hours (healthy)","State":"running"}
        {"ID":"fedcba9876543210","Names":"db","Image":"postgres:16","Command":"docker-entrypoint.sh","CreatedAt":"2026-07-06 09:00:00 +0000 UTC","RunningFor":"3 hours ago","Ports":"5432/tcp","Status":"Exited (0) 1 hour ago","State":"exited"}
        """
        let statsOutput = """
        {"Container":"abcdef123456","Name":"api","CPUPerc":"12.50%","MemUsage":"512MiB / 2GiB","MemPerc":"25.00%","NetIO":"1.5GB / 200MB","BlockIO":"4MB / 8MB","PIDs":"8"}
        """

        let docker = DockerStatsCollector().parseContainers(
            psOutput: psOutput,
            statsOutput: statsOutput,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(docker.isAvailable)
        XCTAssertEqual(docker.containers.count, 2)
        XCTAssertEqual(docker.runningCount, 1)
        XCTAssertEqual(docker.stoppedCount, 1)
        XCTAssertEqual(docker.containers[0].displayName, "api")
        XCTAssertEqual(docker.containers[0].health, .healthy)
        XCTAssertEqual(docker.containers[0].cpuPercent, 12.5)
        XCTAssertEqual(docker.containers[0].memoryUsed, 512 * 1_048_576)
        XCTAssertEqual(docker.containers[0].memoryLimit, 2 * 1_073_741_824)
        XCTAssertEqual(docker.networkRx, 1_500_000_000)
        XCTAssertEqual(docker.networkTx, 200_000_000)
    }

    func testDockerParserAcceptsStatsRowsWithoutPsRows() {
        let statsOutput = """
        {"Container":"redis","Name":"redis","CPUPerc":"0,25%","MemUsage":"128MiB / 1GiB","MemPerc":"12,50%","NetIO":"2kB / 1kB","BlockIO":"0B / 0B","PIDs":"5"}
        """

        let docker = DockerStatsCollector().parseContainers(psOutput: "", statsOutput: statsOutput)

        XCTAssertEqual(docker.containers.count, 1)
        XCTAssertEqual(docker.containers[0].displayName, "redis")
        XCTAssertEqual(docker.containers[0].state, .running)
        XCTAssertEqual(docker.containers[0].cpuPercent, 0.25)
        XCTAssertEqual(docker.containers[0].memoryPercent, 12.5)
        XCTAssertEqual(docker.containers[0].networkRx, 2_000)
        XCTAssertEqual(docker.containers[0].networkTx, 1_000)
    }

    func testDockerParserDeduplicatesRunningAndRecentRows() {
        let psOutput = """
        {"ID":"abcdef1234567890","Names":"api","Image":"ghcr.io/app/api:latest","Status":"Up 2 hours","State":"running"}
        {"ID":"abcdef1234567890","Names":"api","Image":"ghcr.io/app/api:latest","Status":"Up 2 hours","State":"running"}
        """

        let docker = DockerStatsCollector().parseContainers(psOutput: psOutput, statsOutput: "")

        XCTAssertEqual(docker.containers.count, 1)
        XCTAssertEqual(docker.containers[0].displayName, "api")
    }

    func testDockerCommandsUsePowerShellQuotingOnWindowsPowerShell() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell"),
            activeShellName: "powershell",
            powerShellExecutable: "powershell"
        )
        let collector = DockerStatsCollector()

        XCTAssertEqual(
            collector.psCommands(platform: .windows, environment: environment, limit: 24),
            [
                "docker ps --no-trunc --format '{{json .}}' 2>&1",
                "docker ps -a --no-trunc --last 24 --format '{{json .}}' 2>&1"
            ]
        )
        XCTAssertEqual(
            collector.statsCommand(platform: .windows, environment: environment, containerIDs: ["abcdef123456"]),
            "docker stats --no-stream --format '{{json .}}' abcdef123456 2>&1"
        )
        XCTAssertEqual(
            collector.shellCommand(
                for: "docker ps --no-trunc --format '{{json .}}' 2>&1",
                platform: .windows,
                environment: environment
            ),
            "docker ps --no-trunc --format '{{json .}}' 2>&1"
        )
    }

    func testDockerCommandsWrapCmdOnWindowsCMD() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: "powershell"
        )
        let collector = DockerStatsCollector()
        let command = collector.statsCommand(
            platform: .windows,
            environment: environment,
            containerIDs: ["abcdef123456", "unsafe;id"]
        )

        XCTAssertEqual(
            command,
            "docker stats --no-stream --format \"{{json .}}\" abcdef123456 unsafeid 2>&1"
        )
        XCTAssertEqual(
            collector.shellCommand(for: command, platform: .windows, environment: environment),
            "cmd.exe /d /c docker stats --no-stream --format \"{{json .}}\" abcdef123456 unsafeid 2>&1"
        )
    }

    func testDockerActionCommandSanitizesContainerID() throws {
        let container = DockerContainer(
            id: "abcdef123456; rm -rf /",
            name: "api",
            image: "api:latest",
            command: "api",
            state: .running,
            status: "Up",
            health: .none,
            createdAt: "",
            runningFor: "",
            ports: "",
            cpuPercent: 0,
            memoryPercent: 0,
            memoryUsed: nil,
            memoryLimit: nil,
            networkRx: nil,
            networkTx: nil,
            blockRead: nil,
            blockWrite: nil,
            pids: nil
        )

        let collector = DockerStatsCollector()

        XCTAssertEqual(try collector.actionCommand(.start, container: container), "docker start abcdef123456rm-rf 2>&1")
        XCTAssertEqual(try collector.actionCommand(.stop, container: container), "docker stop abcdef123456rm-rf 2>&1")
        XCTAssertEqual(try collector.actionCommand(.restart, container: container), "docker restart abcdef123456rm-rf 2>&1")
    }

    func testDockerCommandsUsePosixQuotingOnUnix() {
        let collector = DockerStatsCollector()

        XCTAssertEqual(
            collector.psCommands(platform: .linux, environment: .fallbackPOSIX, limit: nil),
            ["docker ps -a --no-trunc --format '{{json .}}' 2>&1"]
        )
        XCTAssertEqual(
            collector.shellCommand(
                for: "docker ps -a --no-trunc --format '{{json .}}' 2>&1",
                platform: .linux,
                environment: .fallbackPOSIX
            ),
            "docker ps -a --no-trunc --format '{{json .}}' 2>&1"
        )
    }

    func testDockerSizeParserHandlesBinaryAndDecimalUnits() {
        let collector = DockerStatsCollector()

        XCTAssertEqual(collector.parseSize("512MiB"), 512 * 1_048_576)
        XCTAssertEqual(collector.parseSize("1.5GB"), 1_500_000_000)
        XCTAssertEqual(collector.parseSize("2,5 kB"), 2_500)
        XCTAssertEqual(collector.parseSize("64B"), 64)
    }

    func testDockerSizeParserRejectsOverflowingProducts() {
        let collector = DockerStatsCollector()

        XCTAssertNil(collector.parseSize("16777216TiB"))
        XCTAssertNil(collector.parseSize("100000000TB"))
        XCTAssertNil(collector.parseSize("999999999999999999999999999999999999999B"))
        XCTAssertEqual(collector.parseSize("16777215TiB"), 16_777_215 * 1_099_511_627_776)
    }
}

