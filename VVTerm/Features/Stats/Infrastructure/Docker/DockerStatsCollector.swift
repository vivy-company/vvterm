import Foundation

nonisolated struct DockerStatsCollector: Sendable {
    nonisolated static let periodicContainerLimit = 24

    private let collectionTimeout: Duration = .seconds(8)
    private let actionTimeout: Duration = .seconds(120)

    func collect(
        client: SSHClient,
        platform: RemotePlatform,
        limit: Int? = periodicContainerLimit,
        fallback: DockerStats? = nil
    ) async -> DockerStats {
        let timestamp = Date()
        let environment = await client.remoteEnvironment()

        do {
            let psOutput = try await collectContainerList(
                client: client,
                platform: platform,
                environment: environment,
                limit: limit
            )
            if let availability = unavailableState(from: psOutput) {
                return DockerStats(availability: availability, containers: [], timestamp: timestamp)
            }

            let listedContainers = parseContainers(psOutput: psOutput, statsOutput: "", timestamp: timestamp).containers
            let runningIDs = listedContainers
                .filter(\.isRunning)
                .map(\.id)
                .filter { !$0.isEmpty }

            guard !runningIDs.isEmpty else {
                return DockerStats(availability: .available, containers: listedContainers, timestamp: timestamp)
            }

            let statsOutput = try await executeDockerCommand(
                statsCommand(platform: platform, environment: environment, containerIDs: runningIDs),
                client: client,
                platform: platform,
                environment: environment,
                timeout: collectionTimeout
            )

            if let availability = unavailableState(from: statsOutput) {
                if listedContainers.isEmpty {
                    return DockerStats(availability: availability, containers: [], timestamp: timestamp)
                }
                return DockerStats(availability: .available, containers: listedContainers, timestamp: timestamp)
            }

            return parseContainers(psOutput: psOutput, statsOutput: statsOutput, timestamp: timestamp)
        } catch {
            if isCancellation(error) {
                var stats = fallback ?? DockerStats()
                stats.timestamp = timestamp
                return stats
            }
            return DockerStats(
                availability: .unavailable(error.localizedDescription),
                containers: [],
                timestamp: timestamp
            )
        }
    }

    func perform(
        _ action: DockerContainerAction,
        container: DockerContainer,
        client: SSHClient,
        platform: RemotePlatform
    ) async throws {
        let environment = await client.remoteEnvironment()
        let command = try actionCommand(action, container: container)
        let output: String
        do {
            output = try await executeDockerCommand(
                command,
                client: client,
                platform: platform,
                environment: environment,
                timeout: actionTimeout
            )
        } catch {
            if isCancellation(error) {
                throw CancellationError()
            }
            throw error
        }

        if let availability = unavailableState(from: output) {
            throw DockerControlError.commandFailed(availability.controlFailureMessage)
        }

        let lowercased = output.lowercased()
        if lowercased.contains("error response from daemon")
            || lowercased.hasPrefix("error:")
            || lowercased.contains("no such container") {
            throw DockerControlError.commandFailed(output.firstLine)
        }
    }

    private func collectContainerList(
        client: SSHClient,
        platform: RemotePlatform,
        environment: RemoteEnvironment,
        limit: Int?
    ) async throws -> String {
        var outputs: [String] = []
        var lastError: Error?

        for command in psCommands(platform: platform, environment: environment, limit: limit) {
            do {
                let output = try await executeDockerCommand(
                    command,
                    client: client,
                    platform: platform,
                    environment: environment,
                    timeout: collectionTimeout
                )
                outputs.append(output)
            } catch {
                if isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
            }
        }

        if outputs.isEmpty, let lastError {
            throw lastError
        }
        return outputs.joined(separator: "\n")
    }

    private func executeDockerCommand(
        _ command: String,
        client: SSHClient,
        platform: RemotePlatform,
        environment: RemoteEnvironment,
        timeout: Duration
    ) async throws -> String {
        try await client.execute(
            shellCommand(for: command, platform: platform, environment: environment),
            timeout: timeout
        )
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as NSError).domain == "Swift.CancellationError"
    }

    private func unavailableState(from output: String) -> DockerAvailability? {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let lowercased = cleaned.lowercased()
        if lowercased.contains("command not found")
            || lowercased.contains("not recognized as")
            || lowercased.contains("the term 'docker' is not recognized")
            || lowercased.contains("the term \"docker\" is not recognized")
            || lowercased.contains("no such file or directory") {
            return .commandMissing
        }

        if lowercased.contains("permission denied")
            || lowercased.contains("got permission denied")
            || lowercased.contains("access is denied") {
            return .permissionDenied(cleaned.firstLine)
        }

        if lowercased.contains("cannot connect to the docker daemon")
            || lowercased.contains("is the docker daemon running")
            || lowercased.contains("error during connect")
            || lowercased.contains("docker daemon is not running") {
            return .daemonUnavailable(cleaned.firstLine)
        }

        if lowercased.hasPrefix("error response from daemon")
            || lowercased.hasPrefix("error:") {
            return .unavailable(cleaned.firstLine)
        }

        return nil
    }
}

nonisolated enum DockerControlError: LocalizedError, Sendable {
    case missingContainerID
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingContainerID:
            return String(localized: "Container ID is missing.")
        case .commandFailed(let message):
            return message.isEmpty ? String(localized: "Docker command failed.") : message
        }
    }
}

nonisolated private extension DockerAvailability {
    var controlFailureMessage: String {
        switch self {
        case .unknown:
            return "Docker status is unknown."
        case .available:
            return "Docker is available."
        case .commandMissing:
            return "Docker command not found."
        case .daemonUnavailable(let message),
             .permissionDenied(let message),
             .unavailable(let message):
            return message
        }
    }
}

nonisolated private extension String {
    var firstLine: String {
        components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? self
    }
}
