import Foundation

@MainActor
final class LiveServerStatsCollectionSession: ServerStatsCollectionSession {
    let ownership: ServerStatsClientOwnership

    private let server: Server
    private let credentials: ServerCredentials
    private let client: SSHClient
    private let connectionOperations: SSHConnectionOperationService
    private let knownHostsManager: KnownHostsManager
    private let context = StatsCollectionContext()
    private let dockerCollector = DockerStatsCollector()
    private var remotePlatform: RemotePlatform = .unknown
    private var platformCollector: (any PlatformStatsCollector)?
    private var didDisconnect = false

    init(
        server: Server,
        credentials: ServerCredentials,
        client: SSHClient,
        ownership: ServerStatsClientOwnership,
        connectionOperations: SSHConnectionOperationService,
        knownHostsManager: KnownHostsManager
    ) {
        self.server = server
        self.credentials = credentials
        self.client = client
        self.ownership = ownership
        self.connectionOperations = connectionOperations
        self.knownHostsManager = knownHostsManager
    }

    var connectionIdentity: ServerStatsConnectionIdentity {
        ServerStatsConnectionIdentity(client)
    }

    func runCollection(
        _ operation: @MainActor @Sendable @escaping () async throws -> Void
    ) async throws {
        do {
            try await connectionOperations.runWithConnection(
                using: client,
                server: server,
                credentials: credentials,
                disconnectWhenDone: false
            ) { _ in
                try await operation()
            }
            await disconnect()
        } catch {
            await disconnect()
            if let request = ServerSecurityApprovalRequest.detect(
                error,
                host: server.host,
                port: server.port,
                knownHosts: knownHostsManager
            ) {
                throw ServerStatsApprovalRequired(
                    reference: LiveServerStatsApprovalReference(
                        request,
                        serverID: server.id
                    )
                )
            }
            throw error
        }
    }

    func disconnect() async {
        guard ownership.disconnectWhenDone, !didDisconnect else { return }
        didDisconnect = true
        await client.disconnect()
    }

    func prepareIfNeeded() async -> ServerStatsCollectionPreparation? {
        guard remotePlatform == .unknown else { return nil }

        remotePlatform = await client.remotePlatform()
        platformCollector = remotePlatform.createCollector()
        guard let platformCollector else {
            return ServerStatsCollectionPreparation(
                platformName: remotePlatform.rawValue,
                profile: nil
            )
        }

        let profile: HardwareProfile?
        if let collectedProfile = try? await platformCollector.collectProfile(client: client) {
            profile = collectedProfile
        } else if let systemInfo = try? await platformCollector.getSystemInfo(client: client) {
            profile = HardwareProfile(
                hostname: systemInfo.hostname,
                osInfo: systemInfo.osInfo,
                architecture: "",
                kernelVersion: "",
                cpuModel: "",
                cpuVendor: "",
                cpuCores: systemInfo.cpuCores,
                cpuThreads: systemInfo.cpuCores,
                memoryTotal: 0,
                gpus: [],
                collectedAt: Date()
            )
        } else {
            profile = nil
        }

        return ServerStatsCollectionPreparation(
            platformName: remotePlatform.rawValue,
            profile: profile
        )
    }

    func collectStats(collectDocker: Bool) async throws -> ServerStats {
        _ = await prepareIfNeeded()
        guard let platformCollector else { return ServerStats() }

        var stats = try await platformCollector.collectStats(
            client: client,
            context: context
        )
        if collectDocker {
            if context.shouldCollectDocker(now: stats.timestamp) {
                let dockerStats = await dockerCollector.collect(
                    client: client,
                    platform: remotePlatform,
                    limit: DockerStatsCollector.periodicContainerLimit,
                    fallback: context.getDockerStats()
                )
                context.updateDockerStats(dockerStats, timestamp: stats.timestamp)
                stats.docker = dockerStats
            } else {
                stats.docker = context.getDockerStats()
            }
        }
        return stats
    }

    func terminateProcess(_ process: ProcessInfo) async throws {
        _ = await prepareIfNeeded()
        let command: String
        switch remotePlatform {
        case .windows:
            command = "taskkill /PID \(process.pid) /T /F"
        case .linux, .darwin, .freebsd, .openbsd, .netbsd, .unknown:
            command = "kill -TERM \(process.pid)"
        }
        _ = try await client.execute(command, timeout: .seconds(5))
    }

    func loadProcesses(fallback: [ProcessInfo]) async throws -> [ProcessInfo] {
        _ = await prepareIfNeeded()
        guard let platformCollector else { return fallback }
        let processes = try await platformCollector.collectProcesses(
            client: client,
            context: context
        )
        return processes.isEmpty ? fallback : processes
    }

    func loadDockerStats(fallback: DockerStats) async -> DockerStats {
        _ = await prepareIfNeeded()
        let dockerStats = await dockerCollector.collect(
            client: client,
            platform: remotePlatform,
            limit: nil,
            fallback: fallback
        )
        context.updateDockerStats(dockerStats, timestamp: dockerStats.timestamp)
        return dockerStats
    }

    func performDockerAction(
        _ action: DockerContainerAction,
        on container: DockerContainer,
        fallback: DockerStats
    ) async throws -> DockerStats {
        _ = await prepareIfNeeded()
        try await dockerCollector.perform(
            action,
            container: container,
            client: client,
            platform: remotePlatform
        )
        try? await Task.sleep(for: .milliseconds(500))
        let dockerStats = await dockerCollector.collect(
            client: client,
            platform: remotePlatform,
            limit: nil,
            fallback: fallback
        )
        context.updateDockerStats(dockerStats, timestamp: dockerStats.timestamp)
        return dockerStats
    }

    func loadStorageHealth(for volume: VolumeInfo) async throws -> StorageHealthResult {
        _ = await prepareIfNeeded()
        guard remotePlatform != .unknown,
              let platformCollector else {
            return .unavailable(.unsupported)
        }

        let resolution = try await StorageHealthTargetResolver.resolve(
            client: client,
            platform: remotePlatform,
            volume: volume
        )
        switch resolution {
        case .topology(let topology):
            var members: [StorageHealthMemberReport] = []
            members.reserveCapacity(topology.members.count)
            for (ordinal, member) in topology.members.enumerated() {
                try Task.checkCancellation()
                let result: StorageDeviceHealthResult
                let memberFindings: [StorageHealthFinding]
                switch member {
                case .target(_, let target, let topologyFindings):
                    result = try await platformCollector.collectStorageHealth(
                        client: client,
                        target: target
                    )
                    memberFindings = topologyFindings
                case .unresolved(_, _, let reason):
                    result = .unavailable(reason)
                    memberFindings = []
                }
                members.append(StorageHealthMemberReport(
                    id: member.id,
                    role: member.role,
                    ordinal: ordinal + 1,
                    result: result,
                    findings: memberFindings
                ))
            }

            if topology.kind == .physicalDevice,
               members.count == 1,
               case .unavailable(let reason) = members[0].result {
                return .unavailable(reason)
            }

            let hasUnavailableMember = members.contains { member in
                if case .unavailable = member.result { return true }
                return false
            }
            let coverage: StorageHealthCoverage = topology.coverage == .partial || hasUnavailableMember
                ? .partial
                : .complete
            var findings = topology.findings
            if coverage == .partial,
               !findings.contains(where: { $0.kind == .partialCoverage }) {
                findings.append(StorageHealthFinding(
                    kind: .partialCoverage,
                    severity: .information,
                    source: topology.kind == .zfs ? .zfs : .btrfs
                ))
            }
            return .report(StorageHealthVolumeReport(
                topology: topology.kind,
                name: topology.name,
                coverage: coverage,
                findings: findings,
                members: members
            ))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}
