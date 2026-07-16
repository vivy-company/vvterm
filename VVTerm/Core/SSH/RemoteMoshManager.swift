import Foundation
import MoshBootstrap
import os

actor RemoteMoshManager {
    enum PortClass: String, Equatable, Sendable {
        case privileged
        case standardMoshRange
        case otherUnprivileged
    }

    static let shared = RemoteMoshManager()
    private let logger = Logger(subsystem: "app.vivy.VivyTerm", category: "mosh-bootstrap")
    private static let installSuccessMarker = "__VVTERM_MOSH_INSTALLED__"
    private let availabilityTimeout: Duration = .seconds(8)
    private let bootstrapTimeout: Duration = .seconds(25)
    private let installTimeout: Duration = .seconds(180)
    private let terminateTimeout: Duration = .seconds(5)

    private init() {}

    nonisolated static func portClass(_ port: Int) -> PortClass {
        if port < 1_024 { return .privileged }
        if (60_001...61_000).contains(port) { return .standardMoshRange }
        return .otherUnprivileged
    }

    func isMoshServerAvailable(using client: SSHClient) async -> Bool {
        let okMarker = "__VVTERM_MOSH_OK__"
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); if command -v mosh-server >/dev/null 2>&1; then printf '\(okMarker)'; else printf '__VVTERM_MOSH_NO__'; fi"
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        let output = try? await client.execute(command, timeout: availabilityTimeout)
        return output?.contains(okMarker) == true
    }

    func bootstrapConnectInfo(
        using client: SSHClient,
        startCommand: String?,
        portRange: ClosedRange<Int> = 60001...61000
    ) async throws -> MoshServerConnectInfo {
        let terminalType = await client.remoteTerminalType()
        let resolvedStartup = moshChildStartupScript(
            startCommand: startCommand,
            terminalType: terminalType
        )
        let quotedStartup = RemoteTerminalBootstrap.shellQuoted(resolvedStartup)
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        \(utf8LocaleExportScript());
        mosh-server new -s -c 256 -p \(portRange.lowerBound):\(portRange.upperBound) -- /bin/sh -lc \(quotedStartup) 2>&1
        """
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        logger.info(
            "Starting Mosh bootstrap [custom startup: \(startCommand != nil)] [terminal: \(terminalType.rawValue, privacy: .public)]"
        )
        let output = try await client.execute(command, timeout: bootstrapTimeout)
        return try parseConnectInfo(from: output)
    }

    nonisolated func terminateCommand(pid: Int32) -> String {
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); kill \(pid) 2>/dev/null || true"
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    func terminateMoshServer(pid: Int32, using client: SSHClient) async {
        do {
            _ = try await client.execute(terminateCommand(pid: pid), timeout: terminateTimeout)
            logger.info("Terminated orphaned mosh-server [pid: \(pid)]")
        } catch {
            logger.warning(
                "Could not terminate orphaned mosh-server [pid: \(pid)]: \(error.localizedDescription)"
            )
        }
    }

    func installMoshServer(using client: SSHClient) async throws {
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(installScript()))"
        let output = try await client.execute(command, timeout: installTimeout)
        guard output.contains(Self.installSuccessMarker) else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw SSHError.moshBootstrapFailed("mosh-server installation failed")
            }
            throw SSHError.moshBootstrapFailed(trimmed)
        }
    }

    nonisolated func parseConnectInfo(from output: String) throws -> MoshServerConnectInfo {
        do {
            return try MoshServerOutputParser.parse(output)
        } catch let error as MoshBootstrapError {
            throw mapBootstrapError(error, output: output)
        } catch {
            throw SSHError.moshBootstrapFailed(error.localizedDescription)
        }
    }

    nonisolated func mapBootstrapError(_ error: MoshBootstrapError, output: String? = nil) -> SSHError {
        switch error {
        case .missingServer:
            return .moshServerMissing
        case .permissionDenied:
            return .moshBootstrapFailed("Permission denied while starting mosh-server")
        case .invalidConnectLine:
            return mapInvalidConnectLine(output: output)
        case .invalidPort:
            return .moshBootstrapFailed("mosh-server returned an invalid port")
        case .invalidKey:
            return .moshBootstrapFailed("mosh-server returned an invalid session key")
        case .processExited:
            return .moshBootstrapFailed("mosh-server exited before session startup completed")
        case .timedOut:
            return .moshBootstrapFailed("Timed out waiting for mosh-server startup")
        }
    }

    nonisolated func installScript() -> String {
        """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v mosh-server >/dev/null 2>&1; then printf '\(Self.installSuccessMarker)'; exit 0; fi;
        if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
        OS_NAME="$(uname -s)";
        if [ "$OS_NAME" = "Darwin" ]; then
          if command -v brew >/dev/null 2>&1; then
            brew install mosh;
          elif command -v port >/dev/null 2>&1; then
            $SUDO port install mosh;
          else
            echo "No supported package manager found for macOS.";
          fi;
        elif [ "$OS_NAME" = "Linux" ]; then
          if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update && $SUDO apt-get install -y mosh;
          elif command -v dnf >/dev/null 2>&1; then
            $SUDO dnf install -y mosh;
          elif command -v yum >/dev/null 2>&1; then
            $SUDO yum install -y mosh;
          elif command -v pacman >/dev/null 2>&1; then
            $SUDO pacman -Sy --noconfirm mosh;
          elif command -v apk >/dev/null 2>&1; then
            $SUDO apk add mosh;
          elif command -v zypper >/dev/null 2>&1; then
            $SUDO zypper -n install mosh;
          elif command -v xbps-install >/dev/null 2>&1; then
            $SUDO xbps-install -Sy mosh;
          elif command -v opkg >/dev/null 2>&1; then
            $SUDO opkg update && $SUDO opkg install mosh;
          elif command -v emerge >/dev/null 2>&1; then
            $SUDO emerge net-misc/mosh;
          elif command -v pkg >/dev/null 2>&1; then
            $SUDO pkg install -y mosh;
          else
            echo "No supported package manager found for Linux.";
          fi;
        else
          echo "Unsupported OS: $OS_NAME";
        fi;
        if command -v mosh-server >/dev/null 2>&1; then printf '\(Self.installSuccessMarker)'; else printf '__VVTERM_MOSH_INSTALL_FAILED__'; fi
        """
    }

    nonisolated func moshChildStartupScript(
        startCommand: String?,
        terminalType: RemoteTerminalType = RemoteTerminalBootstrap.defaultTerminalType
    ) -> String {
        """
        \(utf8LocaleExportScript());
        \(RemoteTerminalBootstrap.moshStartupScript(startCommand: startCommand, terminalType: terminalType))
        """
    }

    nonisolated func utf8LocaleExportScript() -> String {
        """
        vvterm_validate_utf8_locale() {
          [ -n "$1" ] || return 1;
          VVTERM_TEST_CHARMAP="$(LANG="$1" LC_ALL="$1" LC_CTYPE="$1" locale charmap 2>/dev/null)" || return 1;
          case "$VVTERM_TEST_CHARMAP" in *[Uu][Tt][Ff]*8*) return 0 ;; *) return 1 ;; esac
        };
        VVTERM_CURRENT_CHARMAP="$(locale charmap 2>/dev/null || true)";
        case "$VVTERM_CURRENT_CHARMAP" in
          *[Uu][Tt][Ff]*8*) VVTERM_UTF8_LOCALE="" ;;
          *)
            VVTERM_UTF8_LOCALE="";
            for VVTERM_LOCALE_CANDIDATE in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}" C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
              if vvterm_validate_utf8_locale "$VVTERM_LOCALE_CANDIDATE"; then
                VVTERM_UTF8_LOCALE="$VVTERM_LOCALE_CANDIDATE";
                break;
              fi;
            done;
            if [ -z "$VVTERM_UTF8_LOCALE" ] && command -v locale >/dev/null 2>&1; then
              for VVTERM_LOCALE_CANDIDATE in $(locale -a 2>/dev/null || true); do
                case "$VVTERM_LOCALE_CANDIDATE" in
                  *[Uu][Tt][Ff]*8*)
                    if vvterm_validate_utf8_locale "$VVTERM_LOCALE_CANDIDATE"; then
                      VVTERM_UTF8_LOCALE="$VVTERM_LOCALE_CANDIDATE";
                      break;
                    fi
                    ;;
                esac;
              done;
            fi;
            if [ -n "$VVTERM_UTF8_LOCALE" ]; then
              export LANG="$VVTERM_UTF8_LOCALE";
              export LC_ALL="$VVTERM_UTF8_LOCALE";
              export LC_CTYPE="$VVTERM_UTF8_LOCALE";
            fi
            ;;
        esac;
        unset VVTERM_CURRENT_CHARMAP VVTERM_LOCALE_CANDIDATE VVTERM_TEST_CHARMAP;
        unset -f vvterm_validate_utf8_locale 2>/dev/null || true
        """
    }

    nonisolated func mapInvalidConnectLine(output: String?) -> SSHError {
        guard let output else {
            return .moshBootstrapFailed("Invalid mosh-server response")
        }
        return .moshBootstrapFailed(bootstrapMessage(for: output))
    }

    nonisolated func bootstrapMessage(for output: String) -> String {
        let sanitized = sanitizedBootstrapOutput(output)
        guard !sanitized.isEmpty else {
            return "Invalid mosh-server response"
        }
        let lowercased = sanitized.lowercased()
        if lowercased.contains("utf-8") || lowercased.contains("utf8") || lowercased.contains("locale") {
            return "mosh-server could not start with a UTF-8 locale: \(sanitized)"
        }
        return "Invalid mosh-server response: \(sanitized)"
    }

    nonisolated func sanitizedBootstrapOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let redacted = trimmed.split(whereSeparator: { $0.isNewline }).map { line in
            line.contains("MOSH CONNECT") ? "MOSH CONNECT <redacted>" : String(line)
        }.joined(separator: "\n")
        let maxLength = 1_500
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength)) + "..."
    }
}
