import Foundation

nonisolated enum RemoteShellFamily: String, Hashable, Sendable {
    case posix
    case powershell
    case cmd
    case unknown
}

nonisolated struct RemoteShellProfile: Hashable, Sendable {
    let family: RemoteShellFamily
    let executableName: String?
    let shellName: String?

    nonisolated var supportsPOSIXExecWrapper: Bool {
        family == .posix
    }

    var supportsPowerShellCommands: Bool {
        family == .powershell
    }

    var supportsOSC7Reporting: Bool {
        switch family {
        case .posix:
            return true
        case .powershell, .cmd, .unknown:
            return false
        }
    }

    nonisolated func launchPlan(startupCommand: String?, bundle: Bundle = .main) -> RemoteShellLaunchPlan {
        let trimmed = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch family {
        case .posix:
            guard !trimmed.isEmpty else {
                let script = RemoteTerminalBootstrap.prefixedPOSIXScript(
                    for: RemoteTerminalBootstrap.defaultLoginShellCommand(),
                    bundle: bundle
                )
                return .exec(RemoteTerminalBootstrap.wrapPOSIXShellCommand(script))
            }
            let script = RemoteTerminalBootstrap.prefixedPOSIXScript(for: trimmed, bundle: bundle)
            return .exec(RemoteTerminalBootstrap.wrapPOSIXShellCommand(script))
        case .powershell:
            guard !trimmed.isEmpty else {
                return .shell
            }
            let executable = executableName ?? "powershell"
            let script = RemoteTerminalBootstrap.prefixedPowerShellScript(for: trimmed, bundle: bundle)
            return .exec(RemoteTerminalBootstrap.wrapPowerShellCommand(script, executableName: executable))
        case .cmd:
            guard !trimmed.isEmpty else {
                return .shell
            }
            return .exec(RemoteTerminalBootstrap.wrapCmdCommand(trimmed))
        case .unknown:
            guard !trimmed.isEmpty else {
                return .shell
            }
            return .shell
        }
    }

    nonisolated func workingDirectoryRestorePlan(
        for path: String,
        powerShellExecutable: String?
    ) -> RemoteWorkingDirectoryRestorePlan {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .keepDefault(.emptyPath) }

        switch family {
        case .posix:
            return .command(RemoteTerminalBootstrap.posixDirectoryChangeCommand(for: path))
        case .powershell:
            return .command(RemoteTerminalBootstrap.powerShellDirectoryChangeCommand(for: path))
        case .cmd:
            return RemoteTerminalBootstrap.cmdWorkingDirectoryRestorePlan(
                for: path,
                powerShellExecutable: powerShellExecutable
            )
        case .unknown:
            return .keepDefault(.unsupportedShell)
        }
    }

    static func posix(shellName: String?) -> RemoteShellProfile {
        RemoteShellProfile(family: .posix, executableName: shellName, shellName: shellName)
    }

    static func powershell(executableName: String?) -> RemoteShellProfile {
        let shellName = executableName?.lowercased()
        return RemoteShellProfile(family: .powershell, executableName: executableName, shellName: shellName)
    }

    static var cmd: RemoteShellProfile {
        RemoteShellProfile(family: .cmd, executableName: "cmd.exe", shellName: "cmd.exe")
    }

    static func unknown(shellName: String? = nil) -> RemoteShellProfile {
        RemoteShellProfile(family: .unknown, executableName: shellName, shellName: shellName)
    }
}

nonisolated struct RemoteEnvironment: Hashable, Sendable {
    let platform: RemotePlatform
    let shellProfile: RemoteShellProfile
    let activeShellName: String?
    let powerShellExecutable: String?

    nonisolated var supportsTmuxRuntime: Bool {
        if platform != .windows {
            return shellProfile.family == .posix
        }

        switch shellProfile.family {
        case .powershell, .cmd:
            return true
        case .posix, .unknown:
            return false
        }
    }

    nonisolated var supportsMoshRuntime: Bool {
        platform != .windows && shellProfile.family == .posix
    }

    nonisolated var supportsWorkingDirectoryRestore: Bool {
        switch shellProfile.family {
        case .posix, .powershell, .cmd:
            return true
        case .unknown:
            return false
        }
    }

    nonisolated static let fallbackPOSIX = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "sh"),
        activeShellName: "sh",
        powerShellExecutable: nil
    )
}

nonisolated enum RemoteEnvironmentResolver {
    typealias CommandExecutor = @Sendable (_ command: String, _ timeout: Duration?) async throws -> String

    private static let probeTimeout: Duration = .seconds(2)
    private static let platformMarker = "__VVTERM_PLATFORM__="
    private static let shellMarker = "__VVTERM_SHELL__="
    private static let windowsDefaultShellMarker = "__VVTERM_DEFAULT_SHELL_BEGIN__"
    private static let windowsPowerShellMarker = "__VVTERM_WINDOWS_POWERSHELL_BEGIN__"
    private static let windowsPwshMarker = "__VVTERM_WINDOWS_PWSH_BEGIN__"
    private static let windowsProbeEndMarker = "__VVTERM_WINDOWS_PROBE_END__"

    static func resolve(using client: SSHClient) async -> RemoteEnvironment {
        await resolve { command, timeout in
            try await client.execute(command, timeout: timeout)
        }
    }

    static func resolve(execute: CommandExecutor) async -> RemoteEnvironment {
        if let output = await probe(posixEnvironmentProbeCommand(), execute: execute),
           let environment = parsePOSIXEnvironmentProbe(output) {
            return environment
        }

        if let output = await probe(windowsEnvironmentProbeCommand(), execute: execute),
           let environment = parseWindowsEnvironmentProbe(output) {
            return environment
        }

        let platform = await detectPlatform(execute: execute)

        switch platform {
        case .windows:
            let activeShell = await detectWindowsShell(execute: execute)
            let powerShellExecutable = await detectPowerShellExecutable(
                execute: execute,
                preferredExecutableName: activeShell.powerShellExecutableName
            )
            let profile: RemoteShellProfile
            switch activeShell {
            case .powershell(_):
                profile = .powershell(executableName: activeShell.powerShellExecutableName ?? powerShellExecutable)
            case .cmd:
                profile = .cmd
            case .unknown:
                profile = .unknown(shellName: nil)
            case .posix:
                profile = .posix(shellName: nil)
            }
            return RemoteEnvironment(
                platform: .windows,
                shellProfile: profile,
                activeShellName: profile.shellName,
                powerShellExecutable: powerShellExecutable
            )

        case .linux, .darwin, .freebsd, .openbsd, .netbsd, .unknown:
            let shellName = await detectUnixShellName(execute: execute)
            let profile = resolveUnixProfile(shellName: shellName)
            return RemoteEnvironment(
                platform: platform,
                shellProfile: profile,
                activeShellName: shellName,
                powerShellExecutable: nil
            )
        }
    }

    nonisolated static func posixEnvironmentProbeCommand() -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        VVTERM_PLATFORM="$(uname -s 2>/dev/null || true)";
        VVTERM_SHELL="${SHELL##*/}";
        if [ -z "$VVTERM_SHELL" ]; then VVTERM_SHELL="$(ps -p $$ -o comm= 2>/dev/null || true)"; fi;
        printf '\(platformMarker)%s\n\(shellMarker)%s' "$VVTERM_PLATFORM" "$VVTERM_SHELL"
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(body)
    }

    nonisolated static func parsePOSIXEnvironmentProbe(_ output: String) -> RemoteEnvironment? {
        let values = output.split(whereSeparator: { $0.isNewline }).reduce(into: [String: String]()) {
            let line = String($1)
            if line.hasPrefix(platformMarker) {
                $0[platformMarker] = String(line.dropFirst(platformMarker.count))
            } else if line.hasPrefix(shellMarker) {
                $0[shellMarker] = String(line.dropFirst(shellMarker.count))
            }
        }
        guard let platformValue = values[platformMarker] else { return nil }
        let platform = RemotePlatform.detect(from: platformValue)
        guard platform != .windows, platform != .unknown else { return nil }
        let shellValue = values[shellMarker]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shellName = shellValue.flatMap { value -> String? in
            let normalized = (value as NSString).lastPathComponent.lowercased()
            return normalized.isEmpty ? nil : normalized
        }
        return RemoteEnvironment(
            platform: platform,
            shellProfile: resolveUnixProfile(shellName: shellName),
            activeShellName: shellName,
            powerShellExecutable: nil
        )
    }

    nonisolated static func windowsEnvironmentProbeCommand() -> String {
        #"cmd.exe /d /c "echo __VVTERM_PLATFORM__=Windows & echo __VVTERM_DEFAULT_SHELL_BEGIN__ & reg query HKLM\SOFTWARE\OpenSSH /v DefaultShell 2>nul & echo __VVTERM_WINDOWS_POWERSHELL_BEGIN__ & where powershell.exe 2>nul & echo __VVTERM_WINDOWS_PWSH_BEGIN__ & where pwsh.exe 2>nul & echo __VVTERM_WINDOWS_PROBE_END__""#
    }

    nonisolated static func parseWindowsEnvironmentProbe(_ output: String) -> RemoteEnvironment? {
        let lines = output.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.contains("\(platformMarker)Windows") else { return nil }

        func section(after startMarker: String, before endMarker: String) -> String {
            guard
                let start = lines.firstIndex(of: startMarker),
                let end = lines[start...].firstIndex(of: endMarker),
                start < end
            else {
                return ""
            }
            return lines[lines.index(after: start)..<end].joined(separator: "\n")
        }

        let defaultShellOutput = section(
            after: windowsDefaultShellMarker,
            before: windowsPowerShellMarker
        )
        let windowsPowerShellOutput = section(
            after: windowsPowerShellMarker,
            before: windowsPwshMarker
        )
        let pwshOutput = section(
            after: windowsPwshMarker,
            before: windowsProbeEndMarker
        )

        let preferredPowerShell = powerShellExecutableName(inWindowsShellOutput: defaultShellOutput)
        let normalizedDefaultShell = defaultShellOutput.lowercased()
        let profile: RemoteShellProfile
        if let preferredPowerShell {
            profile = .powershell(executableName: preferredPowerShell)
        } else if normalizedDefaultShell.contains("defaultshell") {
            if normalizedDefaultShell.contains("cmd.exe") {
                profile = .cmd
            } else {
                profile = .unknown(shellName: nil)
            }
        } else {
            // Windows OpenSSH uses cmd.exe when DefaultShell is not configured.
            profile = .cmd
        }

        let availableWindowsPowerShell = powerShellExecutableName(
            inWindowsShellOutput: windowsPowerShellOutput
        )
        let availablePwsh = powerShellExecutableName(inWindowsShellOutput: pwshOutput)
        let powerShellExecutable = preferredPowerShell
            ?? availableWindowsPowerShell
            ?? availablePwsh

        return RemoteEnvironment(
            platform: .windows,
            shellProfile: profile,
            activeShellName: profile.shellName,
            powerShellExecutable: powerShellExecutable
        )
    }

    private static func detectPlatform(execute: CommandExecutor) async -> RemotePlatform {
        if let output = await probe("cmd.exe /d /c ver", execute: execute) {
            let platform = RemotePlatform.detect(from: output)
            if platform == .windows {
                return .windows
            }
        }

        if let output = await probe("uname -s", execute: execute) {
            return RemotePlatform.detect(from: output)
        }

        if let output = await probe(
            RemoteTerminalBootstrap.wrapPOSIXShellCommand("/usr/bin/uname -s 2>/dev/null || /bin/uname -s 2>/dev/null || uname -s"),
            execute: execute
        ) {
            return RemotePlatform.detect(from: output)
        }

        return .unknown
    }

    private static func detectUnixShellName(execute: CommandExecutor) async -> String? {
        let probes = [
            #"printf '%s' "$SHELL" 2>/dev/null"#,
            #"ps -p $$ -o comm= 2>/dev/null"#,
        ]

        for command in probes {
            guard let output = await probe(command, execute: execute) else { continue }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = (trimmed as NSString).lastPathComponent.lowercased()
            return normalized.isEmpty ? nil : normalized
        }

        return nil
    }

    private static func resolveUnixProfile(shellName: String?) -> RemoteShellProfile {
        guard let shellName else {
            return .posix(shellName: "sh")
        }

        switch shellName {
        case "bash", "zsh", "sh", "dash", "ksh", "ash", "fish", "elvish":
            return .posix(shellName: shellName)
        case "nu", "nushell":
            return .posix(shellName: shellName)
        default:
            return .posix(shellName: shellName)
        }
    }

    nonisolated static func powerShellExecutableCandidates(preferredExecutableName: String?) -> [String] {
        var candidates: [String] = []
        if let preferred = normalizedPowerShellExecutableName(preferredExecutableName) {
            candidates.append(preferred)
        }
        for fallback in ["powershell", "pwsh"] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }

    nonisolated static func powerShellExecutableName(inWindowsShellOutput output: String) -> String? {
        let normalized = output
            .lowercased()
            .replacingOccurrences(of: "\\", with: "/")
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
        let tokens = normalized
            .components(separatedBy: separators)
            .compactMap { token -> String? in
                let executable = token
                    .split(separator: "/")
                    .last
                    .map(String.init)?
                    .replacingOccurrences(of: ".exe", with: "")
                return normalizedPowerShellExecutableName(executable)
            }

        if tokens.contains("pwsh") {
            return "pwsh"
        }
        if tokens.contains("powershell") {
            return "powershell"
        }
        return nil
    }

    private static func detectPowerShellExecutable(
        execute: CommandExecutor,
        preferredExecutableName: String?
    ) async -> String? {
        let marker = "__VVTERM_PWSH_OK__"
        for executable in powerShellExecutableCandidates(preferredExecutableName: preferredExecutableName) {
            if let output = await probe("cmd.exe /d /c where \(executable)", execute: execute),
               output.lowercased().contains(executable) {
                return executable
            }

            if let output = await probe("where \(executable)", execute: execute),
               output.lowercased().contains(executable) {
                return executable
            }

            let command = RemoteTerminalBootstrap.wrapPowerShellCommand("Write-Output '\(marker)'", executableName: executable)
            guard let output = await probe(command, execute: execute) else { continue }
            if output.contains(marker) {
                return executable
            }
        }
        return nil
    }

    private static func detectWindowsShell(execute: CommandExecutor) async -> RemoteWindowsShellDetection {
        if let output = await probe(#"reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell"#, execute: execute) {
            let normalized = output.lowercased()
            if normalized.contains("powershell") || normalized.contains("pwsh") {
                return .powershell(
                    executableName: powerShellExecutableName(inWindowsShellOutput: output)
                )
            }
            if normalized.contains("cmd.exe") {
                return .cmd
            }
        }

        let powerShellMarker = "__VVTERM_ACTIVE_POWERSHELL__"
        if let output = await probe("Write-Output '\(powerShellMarker)'", execute: execute),
           output.contains(powerShellMarker) {
            return .powershell(executableName: nil)
        }

        let cmdMarker = "__VVTERM_ACTIVE_CMD__"
        if let output = await probe("for %I in (1) do @echo \(cmdMarker)", execute: execute),
           output.contains(cmdMarker) {
            return .cmd
        }

        return .unknown
    }

    private static func normalizedPowerShellExecutableName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: ".exe", with: "")
        if normalized == "pwsh" {
            return "pwsh"
        }
        if normalized == "powershell" {
            return "powershell"
        }
        return nil
    }

    private static func probe(_ command: String, execute: CommandExecutor) async -> String? {
        try? await execute(command, probeTimeout)
    }
}

private nonisolated enum RemoteWindowsShellDetection: Equatable {
    case powershell(executableName: String?)
    case cmd
    case posix
    case unknown

    var powerShellExecutableName: String? {
        guard case .powershell(let executableName) = self else { return nil }
        return executableName
    }
}
