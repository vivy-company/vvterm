#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct RemoteTmuxManagerLocalIntegrationTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")))
    func externalAttachPreservesRealTmuxGlobalOptions() throws {
        let installedTmux = "/opt/homebrew/bin/tmux"

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let root = temporaryDirectory
            .appendingPathComponent("vvterm-dev218-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let managedConfigDirectory = home.appendingPathComponent(".vvterm", isDirectory: true)
        let managedConfig = managedConfigDirectory.appendingPathComponent("tmux.conf")
        let fixtureConfig = root.appendingPathComponent("fixture.conf")
        // tmux's default socket suffix exceeds the Unix socket limit inside XCTest's
        // long sandbox path, so the fixture uses a short explicit socket.
        let socket = temporaryDirectory.appendingPathComponent(
            "v218-\(UUID().uuidString.prefix(4))"
        )
        try FileManager.default.createDirectory(
            at: managedConfigDirectory,
            withIntermediateDirectories: true
        )
        try Data("set -g remain-on-exit on\n".utf8).write(to: fixtureConfig)
        try Data("set -g status off\n".utf8).write(to: managedConfig)
        defer {
            try? FileManager.default.removeItem(at: socket)
            try? FileManager.default.removeItem(at: root)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "TMUX")

        let sessionName = "external's;session"
        defer {
            _ = try? runTmux(
                installedTmux,
                socket: socket,
                arguments: ["kill-server"],
                environment: environment
            )
        }

        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: [
                "-f", fixtureConfig.path,
                "new-session", "-d",
                "-s", sessionName
            ],
            environment: environment
        ))
        let customOptions = [
            "status": "on",
            "status-right": "#(date +%s) external-status",
            "history-limit": "100000",
            "mouse": "off",
            "default-terminal": "tmux-256color"
        ]
        for (option, value) in customOptions {
            try setGlobalOption(
                option,
                to: value,
                tmux: installedTmux,
                socket: socket,
                environment: environment
            )
        }
        try setGlobalArrayOption(
            "terminal-features",
            to: "xterm*:extkeys",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        try setServerOption(
            "extended-keys",
            to: "off",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        try setGlobalArrayOption(
            "terminal-overrides",
            to: "*256col*:Tc",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )

        let options = [
            "status",
            "status-right",
            "history-limit",
            "mouse",
            "default-terminal",
            "terminal-features",
            "terminal-overrides"
        ]
        let before = try globalOptions(
            options,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let extendedKeysBefore = try serverOption(
            "extended-keys",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )

        let externalAttach = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: sessionName,
            ownership: .external,
            lifecycleMarkerToken: "integration"
        )
        let socketScopedAttach = """
        tmux() {
          \(installedTmux) -S '\(socket.path)' "$@"
        }
        \(externalAttach)
        """
        let attachResult = try run(
            "/bin/sh",
            ["-c", socketScopedAttach],
            environment: environment
        )
        let detached = TmuxLifecycleMarker.sequence(token: "integration", event: .detached)
        let ended = TmuxLifecycleMarker.sequence(token: "integration", event: .ended)
        #expect(attachResult.output.contains(detached))
        #expect(!attachResult.output.contains(ended))

        let after = try globalOptions(
            options,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let extendedKeysAfter = try serverOption(
            "extended-keys",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        #expect(after == before)
        #expect(extendedKeysAfter == extendedKeysBefore)
    }

    @Test(.enabled(if:
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            && FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish")
    ))
    func managedCreationAndReattachScopeConfigurationToManagedSession() throws {
        let installedTmux = "/opt/homebrew/bin/tmux"
        let installedFish = "/opt/homebrew/bin/fish"
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let root = temporaryDirectory
            .appendingPathComponent("vvterm-dev220-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configDirectory = home.appendingPathComponent(".vvterm", isDirectory: true)
        let config = configDirectory.appendingPathComponent("tmux.conf")
        let fixtureConfig = root.appendingPathComponent("fixture.conf")
        let socket = temporaryDirectory.appendingPathComponent(
            "v220-\(UUID().uuidString.prefix(4))"
        )
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data("set -g remain-on-exit on\n".utf8).write(to: fixtureConfig)
        try Data(
            """
            set -g status off
            set -g history-limit 10000
            set -g mouse on
            set -g set-titles on
            set -g set-titles-string "#{pane_title}"
            set -g default-terminal "xterm-ghostty"
            set -g mode-style "fg=black,bg=green"
            set-environment -g TERM_PROGRAM "vvterm"
            bind -n WheelUpPane if -F '#{alternate_on}' 'send-keys -M' 'copy-mode -eH'
            """.utf8
        ).write(to: config)
        defer {
            try? FileManager.default.removeItem(at: socket)
            try? FileManager.default.removeItem(at: root)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "TMUX")

        let externalSession = "external"
        let managedSession = "vvterm_managed"
        defer {
            _ = try? runTmux(
                installedTmux,
                socket: socket,
                arguments: ["kill-server"],
                environment: environment
            )
        }

        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: [
                "-f", fixtureConfig.path,
                "new-session", "-d",
                "-s", externalSession
            ],
            environment: environment
        ))
        let customOptions = [
            "status": "on",
            "history-limit": "100000",
            "mouse": "off",
            "set-titles": "off",
            "set-titles-string": "EXTERNAL #{session_name}",
            "base-index": "3",
            "default-terminal": "tmux-256color",
            "mode-style": "fg=yellow,bg=blue",
            "default-command": "sleep 0.4; exit 42"
        ]
        for (option, value) in customOptions {
            try setGlobalOption(
                option,
                to: value,
                tmux: installedTmux,
                socket: socket,
                environment: environment
            )
        }
        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: ["set-environment", "-g", "TERM_PROGRAM", "external-terminal"],
            environment: environment
        ))
        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: ["bind-key", "-n", "WheelUpPane", "send-keys", "-M"],
            environment: environment
        ))

        let beforeOptions = try globalOptions(
            Array(customOptions.keys),
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let beforeEnvironment = try globalEnvironment(
            "TERM_PROGRAM",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let beforeBinding = try rootBinding(
            "WheelUpPane",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )

        let managedCreate = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: managedSession,
            workingDirectory: "/tmp",
            lifecycleMarkerToken: "create"
        )
        let legacySocketScopedCreate = """
        tmux() {
          for vvtermArgument in "$@"; do
            if [ "$vvtermArgument" = "-e" ] || [ "$vvtermArgument" = "-T" ]; then
              return 1
            fi
          done
          \(installedTmux) -S '\(socket.path)' "$@"
        }
        \(managedCreate)
        """
        let loginShellCommand = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            legacySocketScopedCreate
        )
        let createResult = try run(
            installedFish,
            ["-c", loginShellCommand],
            environment: environment
        )
        try requireSuccess(createResult)
        Thread.sleep(forTimeInterval: 0.6)

        let sessionProbe = try runTmux(
            installedTmux,
            socket: socket,
            arguments: ["has-session", "-t", "=\(managedSession)"],
            environment: environment
        )
        guard sessionProbe.status == 0 else {
            throw NSError(
                domain: "RemoteTmuxManagerLocalIntegrationTests",
                code: Int(sessionProbe.status),
                userInfo: [
                    NSLocalizedDescriptionKey: """
                    Managed startup output:\n\(createResult.output)
                    Session probe output:\n\(sessionProbe.output)
                    """
                ]
            )
        }

        let managedWindowOptions = [
            "allow-passthrough",
            "allow-set-title",
            "mode-style",
            "scroll-on-clear"
        ]
        let initialWindowTarget = try tmuxFormatValue(
            "window_id",
            target: managedSession,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let initialPaneStartCommand = try tmuxFormatValue(
            "pane_start_command",
            target: initialWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let initialWindowOptions = try windowOptions(
            managedWindowOptions,
            target: initialWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let externalWindowTarget = try tmuxFormatValue(
            "window_id",
            target: externalSession,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let externalWindowOptions = try windowOptions(
            managedWindowOptions,
            target: externalWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let externalHistoryLimit = try tmuxFormatValue(
            "history_limit",
            target: externalWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: [
                "link-window", "-d",
                "-s", "\(externalSession):",
                "-t", "\(managedSession):"
            ],
            environment: environment
        ))
        try requireSuccess(runTmux(
            installedTmux,
            socket: socket,
            arguments: ["select-window", "-t", "\(managedSession):\(externalWindowTarget)"],
            environment: environment
        ))

        let managedReattach = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: managedSession,
            ownership: .managed,
            lifecycleMarkerToken: "reattach"
        )
        let socketScopedReattach = """
        tmux() {
          \(installedTmux) -S '\(socket.path)' "$@"
        }
        \(managedReattach)
        """
        _ = try run("/bin/sh", ["-c", socketScopedReattach], environment: environment)
        #expect(try windowOptions(
            managedWindowOptions,
            target: externalWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        ) == externalWindowOptions)
        #expect(try tmuxFormatValue(
            "history_limit",
            target: externalWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        ) == externalHistoryLimit)

        let newWindow = try runTmux(
            installedTmux,
            socket: socket,
            arguments: [
                "new-window", "-d", "-P",
                "-F", "#{window_id}",
                "-t", "\(managedSession):",
                "sleep 86400"
            ],
            environment: environment
        )
        try requireSuccess(newWindow)
        let newWindowTarget = newWindow.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!newWindowTarget.isEmpty)
        #expect(try windowOptions(
            managedWindowOptions,
            target: newWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        ) == initialWindowOptions)
        let externalStatus = try tmuxFormatValue(
            "status",
            target: externalSession,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let managedStatus = try tmuxFormatValue(
            "status",
            target: newWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let managedMouse = try tmuxFormatValue(
            "mouse",
            target: newWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let managedHistoryLimit = try tmuxFormatValue(
            "history_limit",
            target: newWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let initialWindowIndex = try tmuxFormatValue(
            "window_index",
            target: initialWindowTarget,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let managedColorTerm = try sessionEnvironment(
            "COLORTERM",
            session: managedSession,
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let managedWindows = try runTmux(
            installedTmux,
            socket: socket,
            arguments: ["list-windows", "-t", managedSession, "-F", "#{window_name}"],
            environment: environment
        )
        try requireSuccess(managedWindows)

        let afterOptions = try globalOptions(
            Array(customOptions.keys),
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let afterEnvironment = try globalEnvironment(
            "TERM_PROGRAM",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )
        let afterBinding = try rootBinding(
            "WheelUpPane",
            tmux: installedTmux,
            socket: socket,
            environment: environment
        )

        #expect(afterOptions == beforeOptions)
        #expect(afterEnvironment == beforeEnvironment)
        #expect(afterBinding == beforeBinding)
        #expect(externalStatus == "on")
        #expect(managedStatus == "off")
        #expect(managedMouse == "1")
        #expect(managedHistoryLimit == "10000")
        #expect(initialWindowIndex == "3")
        #expect(managedColorTerm == "COLORTERM=truecolor")
        #expect(!managedWindows.output.contains("__vvterm_bootstrap__"))
        #expect(initialPaneStartCommand.contains("/bin/sh -lc"))
        #expect(!initialPaneStartCommand.contains("sleep 0.4"))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish")))
    func posixWrapperPreservesLiteralBackticksThroughFish() throws {
        let expected = "before`literal`after"
        let script = "printf '%s' \(RemoteTerminalBootstrap.shellQuoted(expected))"
        let command = RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
        let result = try run(
            "/opt/homebrew/bin/fish",
            ["-c", command],
            environment: ProcessInfo.processInfo.environment
        )

        try requireSuccess(result)
        #expect(result.output == expected)
    }

    private func setGlobalOption(
        _ option: String,
        to value: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws {
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-g", option, value],
            environment: environment
        ))
    }

    private func setGlobalArrayOption(
        _ option: String,
        to value: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws {
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-gu", option],
            environment: environment
        ))
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-g", "\(option)[0]", value],
            environment: environment
        ))
    }

    private func setServerOption(
        _ option: String,
        to value: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws {
        try requireSuccess(runTmux(
            tmux,
            socket: socket,
            arguments: ["set-option", "-s", option, value],
            environment: environment
        ))
    }

    private func globalOptions(
        _ options: [String],
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: options.map { option in
            let result = try runTmux(
                tmux,
                socket: socket,
                arguments: ["show-options", "-g", option],
                environment: environment
            )
            try requireSuccess(result)
            return (option, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private func windowOptions(
        _ options: [String],
        target: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: options.map { option in
            let result = try runTmux(
                tmux,
                socket: socket,
                arguments: ["show-options", "-wv", "-t", target, option],
                environment: environment
            )
            try requireSuccess(result)
            return (option, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private func serverOption(
        _ option: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runTmux(
            tmux,
            socket: socket,
            arguments: ["show-options", "-s", option],
            environment: environment
        )
        try requireSuccess(result)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tmuxFormatValue(
        _ option: String,
        target: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runTmux(
            tmux,
            socket: socket,
            arguments: ["display-message", "-p", "-t", target, "#{\(option)}"],
            environment: environment
        )
        try requireSuccess(result)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func globalEnvironment(
        _ variable: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runTmux(
            tmux,
            socket: socket,
            arguments: ["show-environment", "-g", variable],
            environment: environment
        )
        try requireSuccess(result)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionEnvironment(
        _ variable: String,
        session: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runTmux(
            tmux,
            socket: socket,
            arguments: ["show-environment", "-t", session, variable],
            environment: environment
        )
        try requireSuccess(result)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rootBinding(
        _ key: String,
        tmux: String,
        socket: URL,
        environment: [String: String]
    ) throws -> String {
        let result = try runTmux(
            tmux,
            socket: socket,
            arguments: ["list-keys", "-T", "root", key],
            environment: environment
        )
        try requireSuccess(result)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runTmux(
        _ executable: String,
        socket: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CommandResult {
        try run(
            executable,
            ["-S", socket.path] + arguments,
            environment: environment
        )
    }

    private func requireSuccess(_ result: CommandResult) throws {
        guard result.status == 0 else {
            throw NSError(
                domain: "RemoteTmuxManagerLocalIntegrationTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output]
            )
        }
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }
}
#endif
