import Foundation

enum RemoteClipboardTransferPlan: Sendable {
    case posix(uploadStrategy: SSHUploadStrategy)
    case windows(powerShellExecutable: String, terminalShell: RemoteShellFamily)

    nonisolated static func resolve(for environment: RemoteEnvironment) throws -> Self {
        if environment.platform == .windows {
            guard environment.shellProfile.family == .powershell
                    || environment.shellProfile.family == .cmd
            else {
                throw TerminalRichPasteError.unsupportedRemoteShell
            }
            let activePowerShellExecutable = environment.shellProfile.family == .powershell
                ? environment.shellProfile.executableName
                : nil
            guard let powerShellExecutable = environment.powerShellExecutable
                ?? activePowerShellExecutable,
                !powerShellExecutable.isEmpty
            else {
                throw TerminalRichPasteError.unsupportedRemoteShell
            }
            return .windows(
                powerShellExecutable: powerShellExecutable,
                terminalShell: environment.shellProfile.family
            )
        }

        guard environment.shellProfile.family == .posix else {
            throw TerminalRichPasteError.unsupportedRemoteShell
        }
        let strategy: SSHUploadStrategy = environment.platform == .linux ? .automatic : .execPreferred
        return .posix(uploadStrategy: strategy)
    }

    nonisolated var usesSFTP: Bool {
        if case .windows = self {
            return true
        }
        return false
    }

    nonisolated func temporaryPathCommand(fileExtension: String) -> String {
        let sanitizedExtension = Self.sanitizeExtension(fileExtension)
        switch self {
        case .posix:
            return RemoteTerminalBootstrap.wrapPOSIXShellCommand(
                """
                tmp_base="${TMPDIR:-/tmp}";
                tmp_path="$(mktemp "${tmp_base%/}/vvterm-clipboard-XXXXXX")" || exit 1;
                target_path="${tmp_path}.\(sanitizedExtension)";
                mv "$tmp_path" "$target_path" || {
                    rm -f "$tmp_path";
                    exit 1;
                };
                printf '%s\n' "$target_path"
                """
            )
        case .windows(let powerShellExecutable, _):
            let script = """
            $name = 'vvterm-clipboard-' + [Guid]::NewGuid().ToString('N') + '.\(sanitizedExtension)'; $path = [IO.Path]::Combine([IO.Path]::GetTempPath(), $name); [Console]::Out.Write($path)
            """
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                script,
                executableName: powerShellExecutable
            )
        }
    }

    nonisolated func parseTemporaryPath(_ output: String) throws -> String {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.rangeOfCharacter(from: .newlines) == nil,
              path.unicodeScalars.allSatisfy({ $0.value != 0 }),
              Self.isOwnedTemporaryPath(path)
        else {
            throw TerminalRichPasteError.remoteTempFileCreationFailed
        }

        switch self {
        case .posix:
            guard path.hasPrefix("/") else {
                throw TerminalRichPasteError.remoteTempFileCreationFailed
            }
        case .windows:
            guard Self.windowsOpenSSHSFTPPath(from: path) != nil else {
                throw TerminalRichPasteError.remoteTempFileCreationFailed
            }
        }
        return path
    }

    nonisolated func transferPath(for nativePath: String) throws -> String {
        switch self {
        case .posix:
            return nativePath
        case .windows:
            guard let sftpPath = Self.windowsOpenSSHSFTPPath(from: nativePath) else {
                throw TerminalRichPasteError.remoteTempFileCreationFailed
            }
            return sftpPath
        }
    }

    nonisolated func pastedPathToken(for nativePath: String) throws -> String {
        switch self {
        case .posix:
            return RemoteTerminalBootstrap.posixPastedPath(nativePath)
        case .windows(_, let terminalShell):
            switch terminalShell {
            case .powershell:
                return RemoteTerminalBootstrap.powerShellPastedPath(nativePath)
            case .cmd:
                return try RemoteTerminalBootstrap.cmdPastedPath(nativePath)
            case .posix, .unknown:
                throw TerminalRichPasteError.unsupportedRemoteShell
            }
        }
    }

    nonisolated func deleteCommand(for nativePath: String) -> String {
        switch self {
        case .posix:
            let quotedPath = RemoteTerminalBootstrap.shellQuoted(nativePath)
            return RemoteTerminalBootstrap.wrapPOSIXShellCommand("rm -f -- \(quotedPath)")
        case .windows(let powerShellExecutable, _):
            let quotedPath = RemoteTerminalBootstrap.powerShellQuoted(nativePath)
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                "[IO.File]::Delete(\(quotedPath))",
                executableName: powerShellExecutable
            )
        }
    }

    nonisolated var staleSweepCommand: String {
        switch self {
        case .posix:
            return RemoteTerminalBootstrap.wrapPOSIXShellCommand(
                """
                tmp_base="${TMPDIR:-/tmp}";
                for path in "${tmp_base%/}"/vvterm-clipboard-*; do
                    [ -f "$path" ] || continue
                    find "$path" -prune -mtime +1 -exec rm -f -- {} \\; >/dev/null 2>&1 || true
                done
                """
            )
        case .windows(let powerShellExecutable, _):
            let script = """
            $cutoff = [DateTime]::UtcNow.AddDays(-1); Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'vvterm-clipboard-*' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt $cutoff } | ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch {} }
            """
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                script,
                executableName: powerShellExecutable
            )
        }
    }

    nonisolated private static func sanitizeExtension(_ fileExtension: String) -> String {
        let filteredScalars = fileExtension.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
        return sanitized.isEmpty ? "bin" : sanitized.lowercased()
    }

    nonisolated private static func isOwnedTemporaryPath(_ path: String) -> Bool {
        let fileName = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
        return fileName?.hasPrefix("vvterm-clipboard-") == true
    }

    nonisolated private static func windowsOpenSSHSFTPPath(from nativePath: String) -> String? {
        var path = nativePath.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") {
            path.removeFirst()
        }

        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 3,
              Self.isASCIILetter(scalars[0]),
              scalars[1] == ":",
              scalars[2] == "/"
        else {
            return nil
        }
        return "/" + path
    }

    nonisolated private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }
}
