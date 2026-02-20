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
    func installScriptContainsSupportedPackageManagers() {
        let script = RemoteMoshManager.shared.installScript()
        #expect(script.contains("apt-get"))
        #expect(script.contains("dnf"))
        #expect(script.contains("brew"))
        #expect(script.contains("mosh-server"))
    }

    @Test
    func utf8LocaleExportScriptSetsUtf8LocaleVars() {
        let script = RemoteMoshManager.shared.utf8LocaleExportScript()
        #expect(script.contains("locale -a"))
        #expect(script.contains("C.UTF-8"))
        #expect(script.contains("export LANG="))
        #expect(script.contains("export LC_ALL="))
        #expect(script.contains("export LC_CTYPE="))
    }

    @Test
    func resolveStartupCommandUnwrapsShellLaunchWrapper() {
        let wrapped = "sh -lc 'PATH=\"/usr/bin:$PATH\" exec tmux -u -f ~/.vvterm/tmux.conf new-session -A -s '\\''vvterm_test'\\'''"
        let resolved = RemoteMoshManager.shared.resolveStartupCommand(wrapped)
        #expect(!resolved.hasPrefix("sh -lc "))
        #expect(resolved.contains("exec tmux -u -f ~/.vvterm/tmux.conf"))
        #expect(resolved.contains("-s 'vvterm_test'"))
    }

    @Test
    func resolveStartupCommandDefaultsToLoginShell() {
        let resolved = RemoteMoshManager.shared.resolveStartupCommand(nil)
        #expect(resolved == "exec \"${SHELL:-/bin/sh}\" -l")
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
}
