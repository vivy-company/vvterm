import Foundation

actor RemoteTmuxManager {
    static let shared = RemoteTmuxManager()

    private let configDirectory = "~/.vvterm"
    private let configPath = "~/.vvterm/tmux.conf"

    private init() {}

    func isTmuxAvailable(using client: SSHClient) async -> Bool {
        let okMarker = "__VVTERM_TMUX_OK__"
        let body = "\(shellPathExport()); if command -v tmux >/dev/null 2>&1; then printf '\(okMarker)'; else printf '__VVTERM_TMUX_NO__'; fi"
        let command = "sh -lc \(shellQuoted(body))"
        let output = try? await client.execute(command)
        return output?.contains(okMarker) == true
    }

    func prepareConfig(using client: SSHClient) async {
        let body = configWriteCommand()
        let command = "sh -lc \(shellQuoted(body))"
        _ = try? await client.execute(command)
    }

    nonisolated func attachCommand(sessionName: String, workingDirectory: String) -> String {
        let escapedDir = shellDirectoryArgument(workingDirectory)
        let escapedSession = shellQuoted(sessionName)
        return "\(shellPathPrefix()) exec tmux -u -f \(configPath) new-session -A -s \(escapedSession) -c \(escapedDir)"
    }

    nonisolated func attachExecCommand(sessionName: String, workingDirectory: String) -> String {
        let body = attachCommand(sessionName: sessionName, workingDirectory: workingDirectory)
        return "sh -lc \(shellQuoted(body))"
    }

    nonisolated func installAndAttachScript(sessionName: String, workingDirectory: String) -> String {
        let escapedDir = shellDirectoryArgument(workingDirectory)
        let escapedSession = shellQuoted(sessionName)
        let attach = "exec tmux -u -f \(configPath) new-session -A -s \(escapedSession) -c \(escapedDir)"
        let configWrite = configWriteCommand()
        let body = """
        \(shellPathExport());
        \(configWrite);
        if command -v tmux >/dev/null 2>&1; then \(attach); fi;
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
        if command -v tmux >/dev/null 2>&1; then \(attach); else echo "tmux installation failed."; fi
        """
        return "sh -lc \(shellQuoted(body))"
    }

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try? await client.write(data, to: shellId)
    }

    func killSession(named sessionName: String, using client: SSHClient) async {
        let quoted = shellQuoted(sessionName)
        let body = "\(shellPathExport()); tmux kill-session -t \(quoted) 2>/dev/null || true"
        let command = "sh -lc \(shellQuoted(body))"
        _ = try? await client.execute(command)
    }

    func cleanupLegacySessions(using client: SSHClient) async {
        let body = """
        \(shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | awk '$1 ~ /^vvterm_[0-9a-fA-F-]+$/ && $2 == 0 { print $1 }' | while IFS= read -r name; do
            tmux kill-session -t "$name" 2>/dev/null || true;
          done;
        fi
        """
        let command = "sh -lc \(shellQuoted(body))"
        _ = try? await client.execute(command)
    }

    func cleanupDetachedSessions(deviceId: String, keeping sessionNames: Set<String>, using client: SSHClient) async {
        let body = "\(shellPathExport()); tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null"
        let command = "sh -lc \(shellQuoted(body))"
        guard let output = try? await client.execute(command) else { return }

        let prefix = "vvterm_\(deviceId)_"
        let keep = sessionNames

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            guard name.hasPrefix(prefix) else { continue }
            guard let attachedCount = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  attachedCount == 0 else { continue }
            guard !keep.contains(name) else { continue }
            await killSession(named: name, using: client)
        }
    }

    func currentPath(sessionName: String, using client: SSHClient) async -> String? {
        let quotedSession = shellQuoted(sessionName)
        let body = "\(shellPathExport()); tmux list-panes -t \(quotedSession) -F '#{pane_current_path}' 2>/dev/null | head -n 1"
        let command = "sh -lc \(shellQuoted(body))"
        guard let output = try? await client.execute(command) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    nonisolated private func shellDirectoryArgument(_ value: String) -> String {
        if value == "~" {
            return "$HOME"
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private func shellPathPrefix() -> String {
        "PATH=\"\(shellPathValue())\""
    }

    nonisolated private func shellPathExport() -> String {
        "export PATH=\"\(shellPathValue())\""
    }

    nonisolated private func shellPathValue() -> String {
        let paths = [
            "$HOME/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
            "/opt/local/sbin",
            "/snap/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        return paths.joined(separator: ":") + ":$PATH"
    }

    nonisolated private func configWriteCommand() -> String {
        let themeName = UserDefaults.standard.string(forKey: "terminalThemeName") ?? "Aizen Dark"
        let modeStyle = ThemeColorParser.tmuxModeStyle(for: themeName)
        let lines = [
            "# VVTerm tmux configuration",
            "# Auto-generated by VVTerm - changes will be overwritten",
            "",
            "# Keep locale variables so tmux knows UTF-8 is supported",
            "set -ga update-environment \"LANG LC_ALL LC_CTYPE\"",
            "",
            "# Enable hyperlinks (OSC 8)",
            "set -as terminal-features \",*:hyperlinks\"",
            "",
            "# Allow OSC sequences to pass through (title updates, etc.)",
            "set -g allow-passthrough on",
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
            "set -g default-terminal \"xterm-256color\"",
            "set -ag terminal-overrides \",xterm-256color:RGB\"",
            "",
            "# Selection highlighting in copy-mode (from theme: \(themeName))",
            "set -g mode-style \"\(modeStyle)\"",
            "",
            "# Smart mouse scroll: copy-mode at shell, passthrough in TUI apps",
            "bind -n WheelUpPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'copy-mode -eH; send-keys -M'",
            "bind -n WheelDownPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'send-keys -M'"
        ]
        let quotedLines = lines.map { "\"\(escapeForDoubleQuotes($0))\"" }.joined(separator: " ")
        return "mkdir -p \(configDirectory); printf '%s\\n' \(quotedLines) > \(configPath)"
    }

    nonisolated private func escapeForDoubleQuotes(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        escaped = escaped.replacingOccurrences(of: "`", with: "\\`")
        return escaped
    }
}
