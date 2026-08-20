import Foundation
import MoshBootstrap
import os

actor RemoteMoshManager {
    typealias CommandExecutor = SSHMoshCommandExecutor

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
    static let terminationTimeout: Duration = .seconds(5)
    static let disconnectCleanupTimeout: Duration = .seconds(7)

    private init() {}

    nonisolated static func portClass(_ port: Int) -> PortClass {
        if port < 1_024 { return .privileged }
        if (60_001...61_000).contains(port) { return .standardMoshRange }
        return .otherUnprivileged
    }

    func isMoshServerAvailable(using client: SSHClient) async -> Bool {
        let okMarker = "__VVTERM_MOSH_OK__"
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); if command -v mosh-server >/dev/null 2>&1 && mosh-server --version >/dev/null 2>&1; then printf '\(okMarker)'; else printf '__VVTERM_MOSH_NO__'; fi"
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
        return try await bootstrapConnectInfo(
            terminalType: terminalType,
            startCommand: startCommand,
            portRange: portRange,
            execute: { command, timeout in
                try await client.execute(command, timeout: timeout)
            }
        )
    }

    func bootstrapConnectInfo(
        terminalType: RemoteTerminalType,
        startCommand: String?,
        portRange: ClosedRange<Int> = 60001...61000,
        execute: @escaping CommandExecutor
    ) async throws -> MoshServerConnectInfo {
        let command = bootstrapCommand(
            terminalType: terminalType,
            startCommand: startCommand,
            portRange: portRange
        )
        logger.info(
            "Starting Mosh bootstrap [custom startup: \(startCommand != nil)] [terminal: \(terminalType.rawValue, privacy: .public)]"
        )
        let output = try await execute(command, bootstrapTimeout)
        do {
            return try parseConnectInfo(from: output)
        } catch {
            let serverPID = detachedServerPID(from: output)
            await Self.terminateBootstrappedServer(pid: serverPID) { pid in
                await self.terminateMoshServer(pid: pid, execute: execute)
            }
            throw error
        }
    }

    nonisolated func bootstrapCommand(
        terminalType: RemoteTerminalType,
        startCommand: String?,
        portRange: ClosedRange<Int> = 60001...61000
    ) -> String {
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
        let loginShellCommand = "exec /bin/sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        let encodedBody = Data(loginShellCommand.utf8).base64EncodedString()
        // SSH servers parse an exec command with the account's login shell
        // before launching any explicit /bin/sh. Keep that outer command free
        // of shell-specific quoting so fish and POSIX shells decode the same
        // login-shell bootstrap command.
        return "printf %s \(encodedBody) | base64 -d | /bin/sh"
    }

    nonisolated static func terminateBootstrappedServer(
        pid: Int32?,
        terminate: @escaping @Sendable (Int32) async -> Void
    ) async {
        guard let pid, pid > 1 else { return }
        await Task {
            await terminate(pid)
        }.value
    }

    nonisolated static func terminationCommand(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        let body = "kill -TERM \(pid) 2>/dev/null || true"
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    func terminateMoshServer(
        pid: Int32,
        execute: CommandExecutor
    ) async {
        guard let command = Self.terminationCommand(pid: pid) else { return }

        do {
            _ = try await execute(command, Self.terminationTimeout)
            logger.info("Requested cleanup for remote mosh-server [pid: \(pid, privacy: .public)]")
        } catch {
            logger.warning(
                "Could not clean up remote mosh-server [pid: \(pid, privacy: .public)] [error: \(LogPrivacy.errorClass(error), privacy: .public)]"
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
            if isBrokenServerRuntimeOutput(trimmed) {
                throw SSHError.moshServerRuntimeBroken
            }
            throw SSHError.moshBootstrapFailed(sanitizedBootstrapOutput(trimmed))
        }
    }

    nonisolated func parseConnectInfo(from output: String) throws -> MoshServerConnectInfo {
        do {
            let parsed = try MoshServerOutputParser.parse(output)
            return MoshServerConnectInfo(
                port: parsed.port,
                key: parsed.key,
                serverPID: detachedServerPID(from: parsed.rawOutput),
                rawOutput: parsed.rawOutput
            )
        } catch let error as MoshBootstrapError {
            throw mapBootstrapError(error, output: output)
        } catch {
            throw SSHError.moshBootstrapFailed(error.localizedDescription)
        }
    }

    private nonisolated func detachedServerPID(from output: String) -> Int32? {
        let prefix = "[mosh-server detached,"
        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(prefix), line.hasSuffix("]") else { continue }

            let assignment = line.dropFirst(prefix.count).dropLast()
            let fields = assignment.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2,
                  fields[0] == "pid",
                  let pid = Int32(fields[1]),
                  pid > 1 else {
                continue
            }
            return pid
        }
        return nil
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
        vvterm_mosh_server_works() {
          command -v mosh-server >/dev/null 2>&1 && mosh-server --version >/dev/null 2>&1
        };
        if vvterm_mosh_server_works; then printf '\(Self.installSuccessMarker)'; exit 0; fi;
        if command -v mosh-server >/dev/null 2>&1; then VVTERM_MOSH_REPAIR=1; else VVTERM_MOSH_REPAIR=0; fi;
        if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
        OS_NAME="$(uname -s)";
        if [ "$OS_NAME" = "Darwin" ]; then
          if command -v brew >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then brew reinstall mosh; else brew install mosh; fi;
          elif command -v port >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO port upgrade --force mosh; else $SUDO port install mosh; fi;
          else
            echo "No supported package manager found for macOS.";
          fi;
        elif [ "$OS_NAME" = "Linux" ]; then
          if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update && if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO apt-get install --reinstall -y mosh; else $SUDO apt-get install -y mosh; fi;
          elif command -v dnf >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO dnf reinstall -y mosh; else $SUDO dnf install -y mosh; fi;
          elif command -v yum >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO yum reinstall -y mosh; else $SUDO yum install -y mosh; fi;
          elif command -v pacman >/dev/null 2>&1; then
            $SUDO pacman -Sy --noconfirm mosh;
          elif command -v apk >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO apk fix mosh; else $SUDO apk add mosh; fi;
          elif command -v zypper >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO zypper -n install --force mosh; else $SUDO zypper -n install mosh; fi;
          elif command -v xbps-install >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO xbps-install -Sfy mosh; else $SUDO xbps-install -Sy mosh; fi;
          elif command -v opkg >/dev/null 2>&1; then
            $SUDO opkg update && $SUDO opkg install mosh;
          elif command -v emerge >/dev/null 2>&1; then
            $SUDO emerge net-misc/mosh;
          elif command -v pkg >/dev/null 2>&1; then
            if [ "$VVTERM_MOSH_REPAIR" = 1 ]; then $SUDO pkg install -fy mosh; else $SUDO pkg install -y mosh; fi;
          else
            echo "No supported package manager found for Linux.";
          fi;
        else
          echo "Unsupported OS: $OS_NAME";
        fi;
        if vvterm_mosh_server_works; then printf '\(Self.installSuccessMarker)'; else printf '__VVTERM_MOSH_INSTALL_FAILED__'; fi
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
        if isBrokenServerRuntimeOutput(output) {
            return .moshServerRuntimeBroken
        }
        return .moshBootstrapFailed(bootstrapMessage(for: output))
    }

    nonisolated func isBrokenServerRuntimeOutput(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return (normalized.contains("dyld[") && normalized.contains("library not loaded"))
            || normalized.contains("error while loading shared libraries")
            || normalized.contains("symbol lookup error")
            || normalized.contains("exec format error")
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

actor RemoteMoshServerLease {
    typealias Terminate = @Sendable (Int32) async -> Void

    private enum State {
        case bootstrapping
        case cleanupPending
        case active(Int32?)
        case cleaning
        case cleaned
    }

    private let terminate: Terminate
    private var state: State = .bootstrapping
    private var cleanupWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(terminate: @escaping Terminate) {
        self.terminate = terminate
    }

    func activate(serverPID: Int32?) async {
        switch state {
        case .bootstrapping:
            state = .active(serverPID)
        case .cleanupPending:
            await clean(serverPID: serverPID)
        case .active, .cleaning, .cleaned:
            break
        }
    }

    func bootstrapFailed() {
        switch state {
        case .bootstrapping, .cleanupPending:
            state = .cleaned
            resumeCleanupWaiters()
        case .active, .cleaning, .cleaned:
            break
        }
    }

    func cleanup() async {
        switch state {
        case .bootstrapping:
            state = .cleanupPending
            await waitUntilCleaned()
        case .cleanupPending, .cleaning:
            await waitUntilCleaned()
        case .active(let serverPID):
            await clean(serverPID: serverPID)
        case .cleaned:
            break
        }
    }

    #if DEBUG
    func cleanupIsPendingForTesting() -> Bool {
        if case .cleanupPending = state { return true }
        return false
    }
    #endif

    private func clean(serverPID: Int32?) async {
        state = .cleaning
        await RemoteMoshManager.terminateBootstrappedServer(
            pid: serverPID,
            terminate: terminate
        )
        state = .cleaned
        resumeCleanupWaiters()
    }

    private func waitUntilCleaned() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if case .cleaned = state {
                    continuation.resume()
                } else {
                    cleanupWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCleanupWaiter(waiterID) }
        }
    }

    private func cancelCleanupWaiter(_ waiterID: UUID) {
        cleanupWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeCleanupWaiters() {
        let waiters = Array(cleanupWaiters.values)
        cleanupWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
