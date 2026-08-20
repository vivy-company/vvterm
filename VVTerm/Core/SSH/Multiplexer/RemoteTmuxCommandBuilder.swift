import Foundation

nonisolated enum RemoteTmuxCommandBuilder {
    static func attachCommand(
        themeStyle: RemoteTmuxThemeStyle,
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        let body = attachOrCreateBody(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            themeStyle: themeStyle,
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken,
            transport: transport
        )
        return body
    }

    static func attachExistingCommand(
        themeStyle: RemoteTmuxThemeStyle,
        sessionName: String,
        ownership: TmuxSessionOwnership,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        let body = attachExistingBody(
            sessionName: sessionName,
            missingCommand: lifecycleMarkerToken == nil
                ? missingSessionCommand(backend: backend)
                : lifecycleMissingSessionCommand(backend: backend),
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken,
            themeStyle: themeStyle,
            ownership: ownership,
            transport: transport
        )
        return body
    }

    static func sessionPresenceProbeCommand(
        sessionName: String,
        backend: RemoteTmuxBackend = .unixTmux,
        existsMarker: String,
        missingMarker: String
    ) -> String {
        if case .windowsPsmux(let commandName, _, _) = backend {
            let script = """
            $vvtermPsmux = \(powerShellQuoted(commandName))
            $vvtermSession = \(powerShellQuoted(sessionName))
            & $vvtermPsmux has-session -t $vvtermSession 2>$null
            if ($LASTEXITCODE -eq 0) {
              [Console]::Out.Write(\(powerShellQuoted(existsMarker)))
            } else {
              [Console]::Out.Write(\(powerShellQuoted(missingMarker)))
            }
            """
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exists = RemoteTerminalBootstrap.shellQuoted(existsMarker)
        let missing = RemoteTerminalBootstrap.shellQuoted(missingMarker)
        let tmuxProbe = tmuxCommand(includeUTF8: false)
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        printf '%s' \(exists); else printf '%s' \(missing); fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    static func installAndAttachScript(
        themeStyle: RemoteTmuxThemeStyle,
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux,
        attachAfterInstall: Bool = true
    ) -> String {
        if backend.isWindows {
            return windowsInstallAndAttachScript(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                terminalType: terminalType,
                themeStyle: themeStyle,
                backend: backend,
                attachAfterInstall: attachAfterInstall
            )
        }

        let attach = attachCommand(
            themeStyle: themeStyle,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend
        )
        let afterInstall = attachAfterInstall ? attach : ":"

        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          \(afterInstall);
        else
          if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
          OS_NAME="$(uname -s)";
          if [ "$OS_NAME" = "Darwin" ]; then
            if command -v brew >/dev/null 2>&1; then
              brew install tmux;
            elif command -v port >/dev/null 2>&1; then
              $SUDO port install tmux;
            else
              echo "No supported package manager found for macOS.";
            fi;
          elif [ "$OS_NAME" = "Linux" ]; then
            if command -v apt-get >/dev/null 2>&1; then
              $SUDO apt-get update && $SUDO apt-get install -y tmux;
            elif command -v dnf >/dev/null 2>&1; then
              $SUDO dnf install -y tmux;
            elif command -v yum >/dev/null 2>&1; then
              $SUDO yum install -y tmux;
            elif command -v pacman >/dev/null 2>&1; then
              $SUDO pacman -Sy --noconfirm tmux;
            elif command -v apk >/dev/null 2>&1; then
              $SUDO apk add tmux;
            elif command -v zypper >/dev/null 2>&1; then
              $SUDO zypper -n install tmux;
            elif command -v xbps-install >/dev/null 2>&1; then
              $SUDO xbps-install -Sy tmux;
            elif command -v opkg >/dev/null 2>&1; then
              $SUDO opkg update && $SUDO opkg install tmux;
            elif command -v emerge >/dev/null 2>&1; then
              $SUDO emerge app-misc/tmux;
            elif command -v pkg >/dev/null 2>&1; then
              $SUDO pkg install -y tmux;
            else
              echo "No supported package manager found for Linux.";
            fi;
          else
            echo "Unsupported OS: $OS_NAME";
          fi;
        fi;
        if command -v tmux >/dev/null 2>&1; then \(afterInstall); else echo "tmux installation failed."; fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    private static func shellDirectoryArgument(_ value: String) -> String {
        if value == "~" {
            return "\"${HOME}\""
        }
        return RemoteTerminalBootstrap.shellQuoted(value)
    }

    private static func missingSessionCommand(backend: RemoteTmuxBackend) -> String {
        if backend.isWindows {
            return windowsDefaultShellCommand(backend: backend)
        }
        return "exec \"${SHELL:-/bin/sh}\" -l"
    }

    private static func attachOrCreateBody(
        sessionName: String,
        workingDirectory: String,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachOrCreateCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend,
                themeStyle: themeStyle,
                lifecycleMarkerToken: lifecycleMarkerToken
            )
        }

        let createCommand = createSessionCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            themeStyle: themeStyle,
            lifecycleMarkerToken: lifecycleMarkerToken,
            transport: transport
        )
        return attachExistingBody(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            lifecycleMarkerToken: lifecycleMarkerToken,
            themeStyle: themeStyle,
            reportsCreationFailure: true,
            ownership: .managed,
            transport: transport
        )
    }

    private static func attachExistingBody(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend = .unixTmux,
        lifecycleMarkerToken: String? = nil,
        themeStyle: RemoteTmuxThemeStyle,
        reportsCreationFailure: Bool = false,
        ownership: TmuxSessionOwnership,
        transport: ShellTransport = .ssh
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachExistingCommand(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                themeStyle: themeStyle,
                reportsCreationFailure: reportsCreationFailure,
                ownership: ownership
            )
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let tmuxProbe = tmuxCommand(includeUTF8: false)
        let usesManagedConfiguration = ownership == .managed
        let replacesProcess = lifecycleMarkerToken == nil
        let managedConfiguration = usesManagedConfiguration
            ? "\(managedSessionConfigurationCommand(sessionName: sessionName, transport: transport)); \(managedWindowsConfigurationCommand(sessionName: sessionName, themeStyle: themeStyle)); "
            : ""
        let exactAttach = tmuxAttachCommand(
            target: exactSession,
            replacesProcess: replacesProcess,
            advertisesManagedFeatures: usesManagedConfiguration
        )
        let plainAttach = tmuxAttachCommand(
            target: plainSession,
            replacesProcess: replacesProcess,
            advertisesManagedFeatures: usesManagedConfiguration
        )
        let creationStatusCapture = reportsCreationFailure && lifecycleMarkerToken != nil
            ? "; vvtermTmuxCreateStatus=$?"
            : ""

        let lifecycleReport: String
        if let lifecycleMarkerToken {
            let detached = RemoteTerminalBootstrap.shellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .detached)
            )
            let ended = RemoteTerminalBootstrap.shellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .ended)
            )
            if reportsCreationFailure {
                let creationFailed = RemoteTerminalBootstrap.shellQuoted(
                    TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .creationFailed)
                )
                lifecycleReport = """
                ; if [ "${vvtermTmuxCreateStatus:-0}" -ne 0 ]; then printf '%s' \(creationFailed); \
                elif \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
                printf '%s' \(detached); else printf '%s' \(ended); fi
                """
            } else {
                lifecycleReport = """
                ; if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null || \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
                printf '%s' \(detached); else printf '%s' \(ended); fi
                """
            }
        } else {
            lifecycleReport = ""
        }

        return """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null; then \
        \(managedConfiguration)\(exactAttach); \
        elif \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        \(managedConfiguration)\(plainAttach); \
        else \(missingCommand)\(creationStatusCapture); fi\(lifecycleReport)
        """
    }

    private static func createSessionCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux,
        themeStyle: RemoteTmuxThemeStyle,
        lifecycleMarkerToken: String? = nil,
        transport: ShellTransport = .ssh
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsCreateSessionCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            )
        }

        let escapedDir = shellDirectoryArgument(workingDirectory)
        let escapedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let sessionWindowTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let bootstrapWindowName = "__vvterm_bootstrap__"
        let escapedBootstrapWindow = RemoteTerminalBootstrap.shellQuoted(bootstrapWindowName)
        let bootstrapWindowTarget = RemoteTerminalBootstrap.shellQuoted(
            "=\(sessionName):\(bootstrapWindowName)"
        )
        let tmux = tmuxCommand(includeUTF8: false)
        let sessionConfiguration = managedSessionConfigurationCommand(
            sessionName: sessionName,
            transport: transport
        )
        let windowsConfiguration = managedWindowsConfigurationCommand(
            sessionName: sessionName,
            themeStyle: themeStyle
        )
        let createBootstrap = "\(tmux) new-session -d -s \(escapedSession) -n \(escapedBootstrapWindow) -c \(escapedDir) \(RemoteTerminalBootstrap.shellQuoted("sleep 86400"))"
        let loginShell = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            RemoteTerminalBootstrap.defaultLoginShellCommand()
        )
        let createTerminalWindow = "\(tmux) new-window -d -t \(sessionWindowTarget) -c \(escapedDir) \(loginShell)"
        let removeBootstrap = "\(tmux) kill-window -t \(bootstrapWindowTarget)"
        let renumberWindows = "\(tmux) move-window -r -t \(sessionWindowTarget)"
        let removeFailedSession = "\(tmux) kill-session -t \(exactSession) 2>/dev/null"
        let attach = tmuxAttachCommand(
            target: escapedSession,
            replacesProcess: lifecycleMarkerToken == nil,
            advertisesManagedFeatures: true
        )
        return """
        if \(createBootstrap) 2>/dev/null; then \
        if \(sessionConfiguration) && \
        \(createTerminalWindow) 2>/dev/null && \
        \(removeBootstrap) 2>/dev/null && \
        \(renumberWindows) 2>/dev/null && \
        \(windowsConfiguration); then \(attach); \
        else \(removeFailedSession); false; fi; \
        elif \(tmux) has-session -t \(exactSession) 2>/dev/null; then \
        \(sessionConfiguration); \(windowsConfiguration); \(attach); \
        else false; fi
        """
    }

    private static func managedSessionConfigurationCommand(
        sessionName: String,
        transport: ShellTransport
    ) -> String {
        let tmux = tmuxCommand(includeUTF8: false)
        let sessionOptionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let sessionEnvironmentTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let paneTitle = RemoteTerminalBootstrap.shellQuoted("#{pane_title}")

        var commands = [
            "\(tmux) set-option -q -t \(sessionOptionTarget) status off",
            "\(tmux) set-option -q -t \(sessionOptionTarget) history-limit 10000",
            "\(tmux) set-option -q -t \(sessionOptionTarget) mouse on",
            "\(tmux) set-option -q -t \(sessionOptionTarget) set-titles on",
            "\(tmux) set-option -q -t \(sessionOptionTarget) set-titles-string \(paneTitle)"
        ]
        let terminalEnvironment = RemoteTerminalBootstrap.terminalEnvironment(transport: transport)
        commands.append(contentsOf: terminalEnvironment.map { variable in
            let value = RemoteTerminalBootstrap.shellQuoted(variable.value)
            return "\(tmux) set-environment -t \(sessionEnvironmentTarget) \(variable.name) \(value)"
        })
        if !terminalEnvironment.contains(where: {
            $0.name == RemoteKittyGraphicsPolicy.compatibilityEnvironmentName
        }) {
            commands.append(
                "\(tmux) set-environment -u -t \(sessionEnvironmentTarget) \(RemoteKittyGraphicsPolicy.compatibilityEnvironmentName)"
            )
        }
        if !RemoteKittyGraphicsPolicy(transport: transport).supportsKittyGraphics {
            commands.append(contentsOf: RemoteTerminalBootstrap.terminalProgramEnvironment().map { variable in
                "\(tmux) set-environment -u -t \(sessionEnvironmentTarget) \(variable.name)"
            })
        }
        return commands.joined(separator: " && ")
    }

    private static func managedWindowsConfigurationCommand(
        sessionName: String,
        themeStyle: RemoteTmuxThemeStyle
    ) -> String {
        let tmux = tmuxCommand(includeUTF8: false)
        let sessionTarget = RemoteTerminalBootstrap.shellQuoted("=\(sessionName):")
        let settings = [
            (name: "allow-passthrough", value: "on"),
            (name: "allow-set-title", value: "on"),
            (name: "mode-style", value: themeStyle.modeStyle),
            // `clear` sends E3 followed by 2J. Keep this override on each
            // managed window so the visible grid is not restored into history.
            (name: "scroll-on-clear", value: "off")
        ]
        let existingWindowCommands = settings.map { setting in
            let value = RemoteTerminalBootstrap.shellQuoted(setting.value)
            return "\(tmux) set-option -wq -t \"$vvtermWindow\" \(setting.name) \(value)"
        }.joined(separator: " && ")
        let futureWindowCommands = settings.map { setting in
            let value = RemoteTerminalBootstrap.shellQuoted(setting.value)
            return "set-option -wq \(setting.name) \(value)"
        }.joined(separator: " ; ")
        // Window options belong to the window object, so skip linked windows
        // that may also be visible in a user's external session.
        let windowListingFormat = RemoteTerminalBootstrap.shellQuoted(
            "#{window_id} #{window_linked}"
        )
        let unlinkedWindowCondition = RemoteTerminalBootstrap.shellQuoted(
            "#{==:#{window_linked},0}"
        )
        let guardedFutureWindowCommands = [
            "if-shell -F",
            unlinkedWindowCondition,
            RemoteTerminalBootstrap.shellQuoted(futureWindowCommands)
        ].joined(separator: " ")
        // A stable array index makes reattach idempotent without replacing
        // other session-local after-new-window hooks.
        let hookName = RemoteTerminalBootstrap.shellQuoted("after-new-window[1000]")
        let hookCommand = RemoteTerminalBootstrap.shellQuoted(guardedFutureWindowCommands)

        return """
        (vvtermWindows="$(\(tmux) list-windows -t \(sessionTarget) -F \(windowListingFormat) 2>/dev/null)" || exit 1; \
        printf '%s\\n' "$vvtermWindows" | while IFS=' ' read -r vvtermWindow vvtermLinked; do \
        [ "$vvtermLinked" = 0 ] || continue; \(existingWindowCommands) || exit 1; done || exit 1; \
        \(tmux) set-hook -t \(sessionTarget) \(hookName) \(hookCommand) 2>/dev/null || true)
        """
    }

    private static func tmuxAttachCommand(
        target: String,
        replacesProcess: Bool,
        advertisesManagedFeatures: Bool
    ) -> String {
        let processReplacement = replacesProcess ? "exec " : ""
        let tmux = tmuxCommand(includeUTF8: true)
        let attach = "\(processReplacement)\(tmux) attach-session -t \(target)"
        guard advertisesManagedFeatures else { return attach }

        let features = "-T RGB,hyperlinks"
        return "if tmux \(features) -V >/dev/null 2>&1; then \(processReplacement)\(tmux) \(features) attach-session -t \(target); else \(attach); fi"
    }

    private static func lifecycleMissingSessionCommand(backend: RemoteTmuxBackend) -> String {
        backend.isWindows ? "$null" : ":"
    }

    private static func tmuxCommand(
        includeUTF8: Bool
    ) -> String {
        var parts = ["tmux"]
        if includeUTF8 {
            parts.append("-u")
        }
        return parts.joined(separator: " ")
    }

    static func tmuxAvailabilityProbeCommand(okMarker: String) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        VVTERM_TMUX_BIN="";
        if command -v tmux >/dev/null 2>&1; then
          VVTERM_TMUX_BIN="$(command -v tmux 2>/dev/null)";
        fi;
        if [ -z "$VVTERM_TMUX_BIN" ]; then
          for candidate in /usr/bin/tmux /bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /snap/bin/tmux; do
            if [ -x "$candidate" ]; then
              VVTERM_TMUX_BIN="$candidate";
              break;
            fi;
          done;
        fi;
        if [ -n "$VVTERM_TMUX_BIN" ] && "$VVTERM_TMUX_BIN" -V >/dev/null 2>&1; then
          printf '\(okMarker)';
        else
          printf '__VVTERM_TMUX_NO__';
        fi
        """
        return "sh -c \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    static func windowsPowerShellExecutable(
        for environment: RemoteEnvironment
    ) -> String? {
        if let executable = environment.powerShellExecutable, !executable.isEmpty {
            return executable
        }
        guard environment.shellProfile.family == .powershell,
              let executable = environment.shellProfile.executableName,
              !executable.isEmpty else {
            return nil
        }
        return executable
    }

    static func windowsPsmuxAvailabilityProbeCommand(
        commandName: String,
        backend: RemoteTmuxBackend,
        requirePsmuxExtension: Bool
    ) -> String {
        let availableMarker = "__VVTERM_TMUX_OK__:\(commandName)"
        let missingMarker = "__VVTERM_TMUX_NO__:\(commandName)"
        let script = """
        $vvtermAvailable = $false
        $cmd = Get-Command \(powerShellQuoted(commandName)) -ErrorAction SilentlyContinue
        if ($cmd) {
          & $cmd.Source -V *> $null
          if ($LASTEXITCODE -eq 0) {
            $vvtermCommands = (& $cmd.Source list-commands 2>$null) -join "`n"
            if (-not \(requirePsmuxExtension ? "$true" : "$false") -or $vvtermCommands.Contains('dump-state') -or $vvtermCommands.Contains('claim-session')) {
              $vvtermAvailable = $true
            }
          }
        }
        if ($vvtermAvailable) {
          Write-Output \(powerShellQuoted(availableMarker))
        } else {
          Write-Output \(powerShellQuoted(missingMarker))
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    static func listSessionCommands(backend: RemoteTmuxBackend) -> [String] {
        switch backend {
        case .unixTmux:
            let tmux = tmuxCommand(includeUTF8: false)
            let bodies = [
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached} #{session_windows}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions 2>/dev/null"
            ]
            return bodies.map { "sh -lc \(RemoteTerminalBootstrap.shellQuoted($0))" }

        case .windowsPsmux(let commandName, _, _):
            return [
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached} #{session_windows}", backend: backend),
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached}", backend: backend),
                windowsShellCommand(
                    powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions 2>$null",
                    backend: backend
                )
            ]
        }
    }

    private static func windowsPsmuxListSessionsCommand(
        commandName: String,
        format: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions -F \(powerShellQuoted(format)) 2>$null",
            backend: backend
        )
    }

    static func killSessionCommand(named sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend {
        case .unixTmux:
            let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) kill-session -t \(quoted) 2>/dev/null || true"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux(let commandName, _, _):
            let script = "& \(powerShellQuoted(commandName)) kill-session -t \(powerShellQuoted(sessionName)) 2>$null"
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }
    }

    static func currentPathCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend {
        case .unixTmux:
            let quotedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-panes -t \(quotedSession) -F '#{pane_current_path}' 2>/dev/null | head -n 1"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux(let commandName, _, _):
            let script = "& \(powerShellQuoted(commandName)) list-panes -t \(powerShellQuoted(sessionName)) -F '#{pane_current_path}' 2>$null | Select-Object -First 1"
            return windowsShellCommand(powerShellScript: script, backend: backend)
        }
    }

    private static func windowsAttachOrCreateCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteTmuxThemeStyle,
        lifecycleMarkerToken: String?
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachOrCreatePowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend,
                themeStyle: themeStyle,
                lifecycleMarkerToken: lifecycleMarkerToken
            ),
            backend: backend
        )
    }

    private static func windowsAttachExistingCommand(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        lifecycleMarkerToken: String?,
        themeStyle: RemoteTmuxThemeStyle,
        reportsCreationFailure: Bool = false,
        ownership: TmuxSessionOwnership
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachExistingPowerShell(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend,
                themeStyle: themeStyle,
                lifecycleMarkerToken: lifecycleMarkerToken,
                reportsCreationFailure: reportsCreationFailure,
                ownership: ownership
            ),
            backend: backend
        )
    }

    private static func windowsAttachOrCreatePowerShell(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteTmuxThemeStyle,
        commandExpression: String? = nil,
        lifecycleMarkerToken: String? = nil
    ) -> String {
        let createCommand = windowsCreateSessionPowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            commandExpression: commandExpression
        )
        return windowsAttachExistingPowerShell(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            themeStyle: themeStyle,
            commandExpression: commandExpression,
            lifecycleMarkerToken: lifecycleMarkerToken,
            reportsCreationFailure: true,
            ownership: .managed
        )
    }

    private static func windowsAttachExistingPowerShell(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        themeStyle: RemoteTmuxThemeStyle,
        commandExpression: String? = nil,
        lifecycleMarkerToken: String? = nil,
        reportsCreationFailure: Bool = false,
        ownership: TmuxSessionOwnership
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return missingCommand }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        let usesManagedConfiguration = ownership == .managed
        let configDeclaration = usesManagedConfiguration
            ? "$vvtermConfig = \(windowsConfigPathPowerShellExpression())"
            : ""
        let attachCommand = usesManagedConfiguration
            ? """
              & $vvtermPsmux source-file -t $vvtermSession $vvtermConfig 2>$null
              & $vvtermPsmux -u attach-session -d -t $vvtermSession
              """
            : "& $vvtermPsmux -u attach-session -d -t $vvtermSession"
        let lifecycleReport: String
        if let lifecycleMarkerToken {
            let detached = powerShellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .detached)
            )
            let ended = powerShellQuoted(
                TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .ended)
            )
            let sessionPresenceReport = """
            & $vvtermPsmux has-session -t $vvtermSession 2>$null
            if ($LASTEXITCODE -eq 0) {
              [Console]::Out.Write(\(detached))
            } else {
              [Console]::Out.Write(\(ended))
            }
            """
            if reportsCreationFailure {
                let creationFailed = powerShellQuoted(
                    TmuxLifecycleMarker.sequence(token: lifecycleMarkerToken, event: .creationFailed)
                )
                lifecycleReport = """
                if ($null -ne $vvtermTmuxCreateStatus -and $vvtermTmuxCreateStatus -ne 0) {
                  [Console]::Out.Write(\(creationFailed))
                } else {
                  \(sessionPresenceReport)
                }
                """
            } else {
                lifecycleReport = sessionPresenceReport
            }
        } else {
            lifecycleReport = ""
        }

        return """
        $vvtermPsmux = \(psmuxExpression)
        \(configDeclaration)
        $vvtermSession = \(powerShellQuoted(sessionName))
        & $vvtermPsmux has-session -t $vvtermSession 2>$null
        if ($LASTEXITCODE -eq 0) {
        \(indentPowerShell(attachCommand, spaces: 2))
        } else {
        \(indentPowerShell(missingCommand, spaces: 2))
        \(reportsCreationFailure && lifecycleMarkerToken != nil ? "  $vvtermTmuxCreateStatus = $LASTEXITCODE" : "")
        }
        \(lifecycleReport)
        """
    }

    private static func windowsCreateSessionCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsCreateSessionPowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            backend: backend
        )
    }

    private static func windowsCreateSessionPowerShell(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return "" }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        return """
        $vvtermPsmux = \(psmuxExpression)
        $vvtermConfig = \(windowsConfigPathPowerShellExpression())
        $vvtermSession = \(powerShellQuoted(sessionName))
        $vvtermWorkingDirectory = \(windowsWorkingDirectoryExpression(workingDirectory))
        & $vvtermPsmux -u -f $vvtermConfig new-session -A -s $vvtermSession -c $vvtermWorkingDirectory
        """
    }

    private static func windowsDefaultShellCommand(backend: RemoteTmuxBackend) -> String {
        guard case .windowsPsmux(_, let shellFamily, let powerShellExecutable) = backend else { return "" }
        switch shellFamily {
        case .powershell:
            let executable = powerShellExecutable ?? "powershell"
            return "& \(powerShellQuoted(executable))"
        case .cmd:
            return "cmd.exe"
        case .unknown, .posix:
            if let executable = powerShellExecutable {
                return "& \(powerShellQuoted(executable))"
            }
            return ""
        }
    }

    private static func windowsConfigLines(
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle
    ) -> [String] {
        // psmux runs one server per session. VVTerm loads this global-looking
        // config only into the explicitly targeted managed-session server.
        let theme = themeStyle
        var lines = [
            "# VVTerm tmux configuration",
            "# Auto-generated by VVTerm - changes will be overwritten",
            "",
            "# Preserve true-color and terminal metadata when attaching",
        ]
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "update-environment",
            values: RemoteTerminalBootstrap.tmuxUpdateEnvironmentVariables()
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxEnvironmentCommands())
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-features",
            values: ["*:hyperlinks"]
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-overrides",
            values: ["\(terminalType.rawValue):RGB"]
        ))
        lines.append(contentsOf: [
            "",
            "# Allow OSC sequences to pass through (title updates, etc.)",
            "set -g allow-passthrough on",
            "",
            "# Publish the active pane title to the outer VVTerm terminal"
        ])
        lines.append(contentsOf: titlePropagationConfigLines())
        lines.append(contentsOf: [
            "",
            "# Hide status bar",
            "set -g status off",
            "",
            "# Increase scrollback buffer",
            "set -g history-limit 10000",
            "",
            "# Enable mouse support",
            "set -g mouse on",
            "",
            "# Set default terminal with true color support",
            "set -g default-terminal \"\(terminalType.rawValue)\"",
            "",
            "# Selection highlighting in copy-mode (from theme: \(theme.name))",
            "set -g mode-style \"\(theme.modeStyle)\""
        ])

        lines.append(contentsOf: [
            "",
            "# Use psmux's native scroll behavior on Windows"
        ])

        return lines
    }

    static func windowsConfigWriteCommand(
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsConfigWritePowerShell(
                terminalType: terminalType,
                themeStyle: themeStyle
            ),
            backend: backend
        )
    }

    private static func windowsConfigWritePowerShell(
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle
    ) -> String {
        let lines = windowsConfigLines(
            terminalType: terminalType,
            themeStyle: themeStyle
        )
        let content = lines.joined(separator: "\n") + "\n"
        return """
        $vvtermConfigDirectory = \(windowsConfigDirectoryPowerShellExpression())
        $vvtermConfigPath = \(windowsConfigPathPowerShellExpression())
        New-Item -ItemType Directory -Force -Path $vvtermConfigDirectory | Out-Null
        @'
        \(content)'@ | Set-Content -Encoding UTF8 -NoNewline -Path $vvtermConfigPath
        """
    }

    private static func titlePropagationConfigLines() -> [String] {
        [
            "set -g allow-set-title on",
            "set -g set-titles on",
            "set -g set-titles-string \"#{pane_title}\""
        ]
    }

    private static func windowsInstallAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend,
        attachAfterInstall: Bool
    ) -> String {
        let configWrite = windowsConfigWritePowerShell(
            terminalType: terminalType,
            themeStyle: themeStyle
        )
        let attach = windowsAttachOrCreatePowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            themeStyle: themeStyle,
            commandExpression: "$vvtermPsmuxCommand.Source"
        )
        let afterInstall = attachAfterInstall ? attach : "Write-Output 'psmux installation completed.'"
        let script = """
        \(configWrite)
        function Get-VVTermPsmuxCommand {
          $cmd = Get-Command psmux -ErrorAction SilentlyContinue
          if (-not $cmd) {
            $cmd = Get-Command pmux -ErrorAction SilentlyContinue
          }
          return $cmd
        }
        $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
        $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        if (-not $vvtermPsmuxInstalled -and (Get-Command winget -ErrorAction SilentlyContinue)) {
          winget install --id marlocarlo.psmux --accept-package-agreements --accept-source-agreements
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
          scoop bucket add psmux https://github.com/psmux/scoop-psmux
          scoop install psmux
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command choco -ErrorAction SilentlyContinue)) {
          choco install psmux -y
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if (-not $vvtermPsmuxInstalled -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
          cargo install psmux
          $vvtermPsmuxCommand = Get-VVTermPsmuxCommand
          $vvtermPsmuxInstalled = $null -ne $vvtermPsmuxCommand
        }
        if ($vvtermPsmuxInstalled) {
        \(indentPowerShell(afterInstall, spaces: 2))
        } else {
          Write-Output 'psmux installation failed or no supported package manager was found.'
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    private static func windowsShellCommand(
        powerShellScript: String,
        backend: RemoteTmuxBackend
    ) -> String {
        guard case .windowsPsmux(_, let shellFamily, let powerShellExecutable) = backend else {
            return powerShellScript
        }

        switch shellFamily {
        case .powershell:
            return powerShellScript
        case .cmd, .unknown, .posix:
            guard let executable = powerShellExecutable, !executable.isEmpty else {
                return ""
            }
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                powerShellScript,
                executableName: executable
            )
        }
    }

    private static func windowsConfigPathPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm\\psmux.conf"))"
    }

    private static func windowsConfigDirectoryPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm"))"
    }

    private static func windowsWorkingDirectoryExpression(_ value: String) -> String {
        guard !value.isEmpty else { return "$HOME" }
        if value == "~" || value == "$HOME" || value == "%USERPROFILE%" {
            return "$HOME"
        }
        let encoded = Data(normalizedWindowsPath(value).utf8).base64EncodedString()
        return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)'))"
    }

    private static func normalizedWindowsPath(_ value: String) -> String {
        let normalizedSlashes = value.replacingOccurrences(of: "/", with: "\\")
        if value.count >= 2 {
            let prefix = value.prefix(2)
            let drive = prefix.prefix(1)
            if drive.range(of: #"^[A-Za-z]$"#, options: .regularExpression) != nil,
               prefix.dropFirst() == ":" {
                return normalizedSlashes
            }
        }

        if value.count >= 3,
           value.first == "/",
           let drive = value.dropFirst().first,
           drive.isLetter {
            let remainder = value.dropFirst(2)
            let normalizedRemainder = remainder.replacingOccurrences(of: "/", with: "\\")
            return "\(drive.uppercased()):\(normalizedRemainder)"
        }

        return value
    }

    private static func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func indentPowerShell(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }
}
