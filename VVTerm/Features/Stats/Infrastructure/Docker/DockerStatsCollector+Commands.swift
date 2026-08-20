import Foundation

nonisolated extension DockerStatsCollector {
    func psCommands(platform: RemotePlatform, environment: RemoteEnvironment, limit: Int?) -> [String] {
        if let limit {
            return [
                psCommand(platform: platform, environment: environment, limit: nil, allContainers: false),
                psCommand(platform: platform, environment: environment, limit: limit, allContainers: true)
            ]
        }
        return [
            psCommand(platform: platform, environment: environment, limit: nil, allContainers: true)
        ]
    }

    func psCommand(
        platform: RemotePlatform,
        environment: RemoteEnvironment,
        limit: Int?,
        allContainers: Bool
    ) -> String {
        var parts = ["docker", "ps"]
        if allContainers {
            parts.append("-a")
        }
        parts.append("--no-trunc")
        if let limit {
            parts.append(contentsOf: ["--last", "\(limit)"])
        }
        parts.append(contentsOf: ["--format", dockerFormatArgument(platform: platform, environment: environment), "2>&1"])
        return parts.joined(separator: " ")
    }

    func statsCommand(platform: RemotePlatform, environment: RemoteEnvironment, containerIDs: [String]) -> String {
        let ids = containerIDs.map(safeContainerArgument).joined(separator: " ")
        return "docker stats --no-stream --format \(dockerFormatArgument(platform: platform, environment: environment)) \(ids) 2>&1"
    }

    func actionCommand(_ action: DockerContainerAction, container: DockerContainer) throws -> String {
        let id = safeContainerArgument(container.id)
        guard !id.isEmpty else {
            throw DockerControlError.missingContainerID
        }
        switch action {
        case .start:
            return "docker start \(id) 2>&1"
        case .stop:
            return "docker stop \(id) 2>&1"
        case .restart:
            return "docker restart \(id) 2>&1"
        }
    }

    func shellCommand(
        for dockerCommand: String,
        platform: RemotePlatform,
        environment: RemoteEnvironment
    ) -> String {
        switch dockerShell(platform: platform, environment: environment) {
        case .cmd:
            return RemoteTerminalBootstrap.wrapCmdExecCommand(dockerCommand)
        case .posix, .powershell:
            return dockerCommand
        }
    }

    private func dockerFormatArgument(platform: RemotePlatform, environment: RemoteEnvironment) -> String {
        switch dockerShell(platform: platform, environment: environment) {
        case .cmd:
            return "\"{{json .}}\""
        case .posix, .powershell:
            return "'{{json .}}'"
        }
    }

    private func dockerShell(platform: RemotePlatform, environment: RemoteEnvironment) -> DockerShell {
        guard platform == .windows || environment.platform == .windows else {
            return .posix
        }

        switch environment.shellProfile.family {
        case .cmd, .unknown:
            return .cmd
        case .powershell:
            return .powershell
        case .posix:
            return .posix
        }
    }

    private func safeContainerArgument(_ id: String) -> String {
        id.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
    }
}

nonisolated private enum DockerShell {
    case posix
    case powershell
    case cmd
}
