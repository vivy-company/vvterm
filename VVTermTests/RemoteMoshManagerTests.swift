import Foundation
import Testing
import MoshBootstrap
@testable import VVTerm

struct RemoteMoshManagerTests {
    @Test
    func parseValidMoshConnectOutput() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let output = """
        MOSH CONNECT 60001 \(key)
        mosh-server (mosh 1.4.0) [pid=12345]
        """

        let info = try RemoteMoshManager.shared.parseConnectInfo(from: output)
        #expect(info.port == 60001)
        #expect(info.key == key)
    }

    @Test
    func parseMissingServerMapsToTypedSSHError() {
        do {
            _ = try RemoteMoshManager.shared.parseConnectInfo(from: "mosh-server: command not found")
            Issue.record("Expected moshServerMissing error")
        } catch let error as SSHError {
            guard case .moshServerMissing = error else {
                Issue.record("Unexpected SSHError: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func parseMalformedOutputMapsToBootstrapError() {
        do {
            _ = try RemoteMoshManager.shared.parseConnectInfo(from: "MOSH CONNECT")
            Issue.record("Expected moshBootstrapFailed error")
        } catch let error as SSHError {
            guard case .moshBootstrapFailed = error else {
                Issue.record("Unexpected SSHError: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func bootstrapDiagnosticsRedactMoshSessionKeys() {
        let output = "MOSH CONNECT invalid-port ABCDEFGHIJKLMNOPQRSTUV\nother detail"

        let sanitized = RemoteMoshManager.shared.sanitizedBootstrapOutput(output)

        #expect(sanitized.contains("MOSH CONNECT <redacted>"))
        #expect(!sanitized.contains("ABCDEFGHIJKLMNOPQRSTUV"))
        #expect(sanitized.contains("other detail"))
    }

    @Test
    func installScriptContainsSupportedPackageManagers() {
        let script = RemoteMoshManager.shared.installScript()
        #expect(script.contains("apt-get"))
        #expect(script.contains("dnf"))
        #expect(script.contains("brew"))
        #expect(script.contains("mosh-server"))
    }

    @Test
    func terminateCommandKillsTheBootstrappedServerPID() {
        let command = RemoteMoshManager.shared.terminateCommand(pid: 4321)
        #expect(command.hasPrefix("sh -lc "))
        #expect(command.contains("kill 4321"))
        #expect(command.contains("2>/dev/null || true"))
    }

    @Test
    func utf8LocaleExportScriptSetsUtf8LocaleVars() {
        let script = RemoteMoshManager.shared.utf8LocaleExportScript()
        #expect(script.contains("locale -a"))
        #expect(script.contains("locale charmap"))
        #expect(script.contains("C.UTF-8"))
        #expect(script.contains("vvterm_validate_utf8_locale"))
        #expect(script.contains("[Uu][Tt][Ff]*8"))
        #expect(script.contains("VVTERM_LOCALE_CANDIDATE"))
        #expect(script.contains("awk") == false)
        #expect(script.contains("IGNORECASE") == false)
        #expect(script.contains("export LANG="))
        #expect(script.contains("export LC_ALL="))
        #expect(script.contains("export LC_CTYPE="))
    }

    @Test
    func moshChildStartupScriptAlsoSetsUtf8Locale() {
        let script = RemoteMoshManager.shared.moshChildStartupScript(
            startCommand: "echo hi",
            terminalType: .xtermGhostty
        )

        #expect(script.contains("VVTERM_UTF8_LOCALE"))
        #expect(script.contains("TERM='xterm-ghostty'"))
        #expect(script.contains("echo hi"))
    }

    @Test
    func localeBootstrapErrorMessageIsSpecific() {
        let error = RemoteMoshManager.shared.mapInvalidConnectLine(
            output: "mosh-server needs a UTF-8 native locale to run."
        )

        switch error {
        case .moshBootstrapFailed(let message):
            #expect(message.contains("UTF-8 locale"))
            #expect(message.contains("mosh-server needs a UTF-8 native locale"))
        default:
            Issue.record("Expected moshBootstrapFailed for invalid connect line")
        }
    }

    @Test
    func moshStartupScriptContainsDefaultShell() {
        let script = RemoteTerminalBootstrap.moshStartupScript(startCommand: nil)
        #expect(script.contains("$SHELL"))
        #expect(script.contains("TERM='xterm-256color'"))
    }

    @Test
    func moshStartupScriptUsesResolvedTerminalTypeWhenProvided() {
        let script = RemoteTerminalBootstrap.moshStartupScript(
            startCommand: "echo hi",
            terminalType: .xtermGhostty
        )
        #expect(script.contains("TERM='xterm-ghostty'"))
        #expect(script.contains("echo hi"))
    }

    @Test
    func mapBootstrapPermissionDeniedProducesReadableSSHError() {
        let mapped = RemoteMoshManager.shared.mapBootstrapError(.permissionDenied)
        switch mapped {
        case .moshBootstrapFailed(let message):
            #expect(message.contains("Permission denied"))
        default:
            Issue.record("Expected moshBootstrapFailed for permissionDenied")
        }
    }

    @Test
    func endpointCandidatesPreferConfiguredHostThenDistinctSSHPeer() {
        #expect(
            MoshEndpointCandidatePolicy.hosts(
                configuredHost: "server.example.com",
                sshPeerHost: "100.64.0.10"
            ) == ["server.example.com", "100.64.0.10"]
        )
        #expect(
            MoshEndpointCandidatePolicy.hosts(
                configuredHost: "100.64.0.10",
                sshPeerHost: "100.64.0.10"
            ) == ["100.64.0.10"]
        )
    }

    @Test
    func fallbackReasonsAreActionable() {
        #expect(MoshFallbackReason.bootstrapFailed.bannerMessage.contains("could not start"))
        #expect(MoshFallbackReason.invalidEndpoint.bannerMessage.contains("address"))
        #expect(MoshFallbackReason.udpTimeout.bannerMessage.contains("UDP"))
        #expect(MoshFallbackReason.clientSessionFailed.bannerMessage.contains("client session"))
    }

    @Test
    func moshPortClassificationDoesNotExposeExactPort() {
        #expect(RemoteMoshManager.portClass(60001) == .standardMoshRange)
        #expect(RemoteMoshManager.portClass(22) == .privileged)
        #expect(RemoteMoshManager.portClass(50_000) == .otherUnprivileged)
    }
}
