import Foundation
import os

nonisolated enum RemoteTerminalTypeResolver {
    typealias CommandExecutor = @Sendable (_ command: String, _ timeout: Duration?) async throws -> String

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "RemoteTerminalTypeResolver"
    )
    private static let probeTimeout: Duration = .seconds(5)
    private static let installTimeout: Duration = .seconds(12)
    private static let probeMarker = "__VVTERM_XTERM_GHOSTTY_OK__"
    private static let probeMissMarker = "__VVTERM_XTERM_GHOSTTY_NO__"
    private static let installMarker = "__VVTERM_XTERM_GHOSTTY_INSTALLED__"
    private static let missingTicMarker = "__VVTERM_XTERM_GHOSTTY_NO_TIC__"
    private static let installFailedMarker = "__VVTERM_XTERM_GHOSTTY_INSTALL_FAILED__"
    private static let hereDocMarker = "__VVTERM_XTERM_GHOSTTY_TERMINFO__"

    private enum InstallResult: Sendable {
        case installed
        case missingTic
        case failed
    }

    static func resolve(
        environment: RemoteEnvironment,
        execute: CommandExecutor,
        bundle: Bundle = .main,
        terminfoSource: String? = nil
    ) async -> RemoteTerminalType {
        guard environment.shellProfile.family == .posix else {
            return RemoteTerminalBootstrap.defaultTerminalType
        }

        let resolvedTerminfoSource = terminfoSource ?? RemoteTerminalBootstrap.ghosttyTerminfoSource(bundle: bundle)
        guard let resolvedTerminfoSource else {
            if await remoteHasGhosttyTerminfo(execute: execute) {
                return .xtermGhostty
            }
            logger.warning("Ghostty terminfo source not found in bundle; falling back to \(RemoteTerminalBootstrap.defaultTerminalType.rawValue, privacy: .public)")
            return RemoteTerminalBootstrap.defaultTerminalType
        }

        switch await installGhosttyTerminfo(source: resolvedTerminfoSource, execute: execute) {
        case .installed:
            return .xtermGhostty
        case .missingTic:
            logger.info("Remote host does not provide tic; keeping compatibility TERM")
            return RemoteTerminalBootstrap.defaultTerminalType
        case .failed:
            logger.info("Ghostty terminfo installation failed; keeping compatibility TERM")
            return RemoteTerminalBootstrap.defaultTerminalType
        }
    }

    static func probeCommand(okMarker: String = probeMarker) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        \(currentGhosttyTerminfoFunction())
        if vvterm_xterm_ghostty_is_current; then
          printf '\(okMarker)';
        else
          printf '\(probeMissMarker)';
        fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    static func installCommand(
        terminfoSource: String,
        okMarker: String = installMarker,
        missingTicMarker: String = missingTicMarker,
        failedMarker: String = installFailedMarker
    ) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        \(currentGhosttyTerminfoFunction())
        if vvterm_xterm_ghostty_is_current; then
          printf '\(okMarker)';
          exit 0;
        fi;
        if ! command -v tic >/dev/null 2>&1; then
          printf '\(missingTicMarker)';
          exit 0;
        fi;
        if ! mkdir -p "$HOME/.terminfo" 2>/dev/null; then
          printf '\(failedMarker)';
          exit 0;
        fi;
        cat <<'\(hereDocMarker)' | tic -x -o "$HOME/.terminfo" - >/dev/null 2>&1
        \(terminfoSource.trimmingCharacters(in: .newlines))
        \(hereDocMarker)
        if [ $? -eq 0 ]; then
          if ! command -v infocmp >/dev/null 2>&1 || vvterm_xterm_ghostty_is_current; then
            printf '\(okMarker)';
          else
            printf '\(failedMarker)';
          fi;
        else
          printf '\(failedMarker)';
        fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    private static func remoteHasGhosttyTerminfo(execute: CommandExecutor) async -> Bool {
        do {
            let output = try await execute(probeCommand(), probeTimeout)
            return output.contains(probeMarker)
        } catch {
            logger.debug("Ghostty terminfo probe failed [error: \(LogPrivacy.errorClass(error), privacy: .public)]")
            return false
        }
    }

    private static func installGhosttyTerminfo(
        source: String,
        execute: CommandExecutor
    ) async -> InstallResult {
        do {
            let output = try await execute(installCommand(terminfoSource: source), installTimeout)
            if output.contains(installMarker) {
                return .installed
            }
            if output.contains(missingTicMarker) {
                return .missingTic
            }
            return .failed
        } catch {
            logger.debug("Ghostty terminfo installation command failed [error: \(LogPrivacy.errorClass(error), privacy: .public)]")
            return .failed
        }
    }

    private static func currentGhosttyTerminfoFunction() -> String {
        """
        vvterm_xterm_ghostty_is_current() {
          command -v infocmp >/dev/null 2>&1 || return 1;
          LC_ALL=C infocmp -1 -x xterm-ghostty 2>/dev/null |
            grep -F 'E3=\\E[3J,' >/dev/null 2>&1;
        }
        """
    }
}
