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
        [mosh-server detached, pid = 12345]
        """

        let info = try RemoteMoshManager.shared.parseConnectInfo(from: output)
        #expect(info.port == 60001)
        #expect(info.key == key)
        #expect(info.serverPID == 12_345)
    }

    @Test
    func parseIgnoresUnrelatedPIDTextForCleanup() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let output = """
        shell startup pid = 4242
        MOSH CONNECT 60001 \(key)
        """

        let info = try RemoteMoshManager.shared.parseConnectInfo(from: output)

        #expect(info.serverPID == nil)
    }

    @Test
    func malformedBootstrapWithDetachedPIDTerminatesServer() async {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let executor = MoshTerminationExecutor(results: [
            .success("""
            MOSH CONNECT invalid-port \(key)
            [mosh-server detached, pid = 12345]
            """),
            .success("")
        ])

        do {
            _ = try await RemoteMoshManager.shared.bootstrapConnectInfo(
                terminalType: .xterm256Color,
                startCommand: nil,
                execute: { command, timeout in
                    try await executor.execute(command: command, timeout: timeout)
                }
            )
            Issue.record("Expected malformed bootstrap failure")
        } catch let error as SSHError {
            guard case .moshBootstrapFailed = error else {
                Issue.record("Unexpected SSHError: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        let invocations = await executor.snapshot()
        #expect(invocations.count == 2)
        #expect(invocations[1].command.contains("kill -TERM 12345"))
        #expect(invocations[1].timeout == .seconds(5))
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
    func brokenDynamicLibraryMapsToRepairableRuntimeErrorWithoutExposingItInFallbackState() {
        let output = """
        dyld[86054]: Library not loaded: /opt/homebrew/opt/protobuf/lib/libprotobuf.34.0.0.dylib
          Referenced from: /opt/homebrew/Cellar/mosh/1.4.0/bin/mosh-server
        """

        do {
            _ = try RemoteMoshManager.shared.parseConnectInfo(from: output)
            Issue.record("Expected broken mosh-server runtime")
        } catch let error as SSHError {
            guard case .moshServerRuntimeBroken = error else {
                Issue.record("Unexpected SSHError: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(!MoshFallbackReason.serverRuntimeBroken.bannerMessage.contains("/opt/homebrew"))
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
        #expect(script.contains("mosh-server --version"))
        #expect(script.contains("brew reinstall mosh"))
        #expect(script.contains("apt-get install --reinstall"))
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
        #expect(!script.contains("TERM_PROGRAM"))
        #expect(script.contains("echo hi"))
    }

    @Test
    func managedTmuxBootstrapKeepsNestedQuotingOutOfLoginShell() throws {
        let startCommand = RemoteTmuxCommandBuilder.attachCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "vvterm_dev223",
            workingDirectory: "~",
            lifecycleMarkerToken: "dev223-marker"
        )
        let command = RemoteMoshManager.shared.bootstrapCommand(
            terminalType: .xtermGhostty,
            startCommand: startCommand
        )
        let prefix = "printf %s "
        let suffix = " | base64 -d | /bin/sh"

        #expect(command.hasPrefix(prefix))
        #expect(command.hasSuffix(suffix))
        #expect(!command.contains("'"))
        #expect(!command.contains("\""))
        #expect(!command.contains("\\"))
        #expect(!command.contains("\n"))

        let encodedStart = command.index(command.startIndex, offsetBy: prefix.count)
        let encodedEnd = command.index(command.endIndex, offsetBy: -suffix.count)
        let encodedBody = String(command[encodedStart..<encodedEnd])
        let decodedData = try #require(Data(base64Encoded: encodedBody))
        let decodedBody = try #require(String(data: decodedData, encoding: .utf8))

        #expect(decodedBody.hasPrefix("exec /bin/sh -lc "))
        #expect(decodedBody.contains("mosh-server new"))
        #expect(decodedBody.contains("vvterm_dev223"))
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

    @Test
    func activatingServerLeaseDoesNotTerminateIt() async {
        let recorder = MoshCleanupRecorder()
        let lease = RemoteMoshServerLease(
            terminate: { pid in await recorder.record(pid: pid) }
        )

        await lease.activate(serverPID: 12_345)

        #expect(await recorder.snapshot().isEmpty)
    }

    @Test
    func activeServerLeaseCleanupTerminatesExactlyOnce() async {
        let recorder = MoshCleanupRecorder()
        let lease = RemoteMoshServerLease(
            terminate: { pid in await recorder.record(pid: pid) }
        )
        await lease.activate(serverPID: 12_345)

        async let firstCleanup: Void = lease.cleanup()
        async let secondCleanup: Void = lease.cleanup()
        await firstCleanup
        await secondCleanup

        #expect(await recorder.snapshot() == [
            MoshCleanupEvent(pid: 12_345, wasCancelled: false)
        ])
    }

    @Test
    func cancelledLeaseCleanupTerminatesFromUncancelledTask() async {
        let recorder = MoshCleanupRecorder()
        let lease = RemoteMoshServerLease(
            terminate: { pid in await recorder.record(pid: pid) }
        )
        await lease.activate(serverPID: 12_345)
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            for await _ in release.stream { break }
            await lease.cleanup()
        }

        task.cancel()
        release.continuation.yield()
        release.continuation.finish()
        await task.value

        #expect(await recorder.snapshot() == [
            MoshCleanupEvent(pid: 12_345, wasCancelled: false)
        ])
    }

    @Test
    func cleanupRequestedDuringBootstrapRunsWhenPIDArrives() async {
        let recorder = MoshCleanupRecorder()
        let lease = RemoteMoshServerLease(
            terminate: { pid in await recorder.record(pid: pid) }
        )
        let cleanup = Task { await lease.cleanup() }

        var cleanupIsPending = false
        for _ in 0..<1_000 {
            if await lease.cleanupIsPendingForTesting() {
                cleanupIsPending = true
                break
            }
            await Task.yield()
        }
        guard cleanupIsPending else {
            await lease.bootstrapFailed()
            await cleanup.value
            Issue.record("Lease cleanup did not wait for bootstrap resolution")
            return
        }

        await lease.activate(serverPID: 12_345)
        await cleanup.value

        #expect(await recorder.snapshot() == [
            MoshCleanupEvent(pid: 12_345, wasCancelled: false)
        ])
    }

    @Test
    func cancelledDisconnectCleanupWaitsForPIDBeforeTeardown() async {
        let recorder = MoshDisconnectCleanupRecorder()
        let lease = RemoteMoshServerLease(
            terminate: { pid in await recorder.recordTermination(pid: pid) }
        )
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cleanup = Task {
            for await _ in release.stream { break }
            let callerWasCancelled = Task.isCancelled
            let cleanupFinished = await SSHClient.cleanupPendingMoshServerLeases([lease])
            await recorder.recordTeardown()
            return (callerWasCancelled, cleanupFinished)
        }

        cleanup.cancel()
        release.continuation.yield()
        release.continuation.finish()

        var cleanupIsPending = false
        for _ in 0..<1_000 {
            if await lease.cleanupIsPendingForTesting() {
                cleanupIsPending = true
                break
            }
            await Task.yield()
        }
        guard cleanupIsPending else {
            await lease.bootstrapFailed()
            _ = await cleanup.value
            Issue.record("Disconnect cleanup did not wait for bootstrap resolution")
            return
        }

        await lease.activate(serverPID: 12_345)
        let result = await cleanup.value

        #expect(result.0)
        #expect(result.1)
        #expect(await recorder.snapshot() == [
            .termination(pid: 12_345, wasCancelled: false),
            .teardown
        ])
    }

    @Test
    func missingOrUnsafePIDSkipsTermination() async {
        let recorder = MoshCleanupRecorder()

        for pid in [nil, Int32.min, -1, 0, 1] as [Int32?] {
            await RemoteMoshManager.terminateBootstrappedServer(
                pid: pid,
                terminate: { value in await recorder.record(pid: value) }
            )
        }
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test
    func terminationExecutesBoundedBestEffortCommand() async {
        let executor = MoshTerminationExecutor(error: MoshCleanupTestError.commandFailed)

        await RemoteMoshManager.shared.terminateMoshServer(
            pid: 12_345,
            execute: { command, timeout in
                try await executor.execute(command: command, timeout: timeout)
            }
        )

        let invocations = await executor.snapshot()
        #expect(invocations.count == 1)
        #expect(invocations[0].command.contains("kill -TERM 12345"))
        #expect(invocations[0].timeout == .seconds(5))
    }

    @Test
    func terminationCommandRejectsUnsafePIDs() {
        #expect(RemoteMoshManager.terminationCommand(pid: Int32.min) == nil)
        #expect(RemoteMoshManager.terminationCommand(pid: -1) == nil)
        #expect(RemoteMoshManager.terminationCommand(pid: 0) == nil)
        #expect(RemoteMoshManager.terminationCommand(pid: 1) == nil)
        #expect(RemoteMoshManager.terminationCommand(pid: 2)?.contains("kill -TERM 2") == true)
    }
}

private enum MoshCleanupTestError: Error, Equatable, Sendable {
    case commandFailed
}

private struct MoshCleanupEvent: Equatable, Sendable {
    let pid: Int32
    let wasCancelled: Bool
}

private actor MoshCleanupRecorder {
    private var events: [MoshCleanupEvent] = []

    func record(pid: Int32) {
        events.append(MoshCleanupEvent(pid: pid, wasCancelled: Task.isCancelled))
    }

    func snapshot() -> [MoshCleanupEvent] {
        events
    }
}

private enum MoshDisconnectCleanupEvent: Equatable, Sendable {
    case termination(pid: Int32, wasCancelled: Bool)
    case teardown
}

private actor MoshDisconnectCleanupRecorder {
    private var events: [MoshDisconnectCleanupEvent] = []

    func recordTermination(pid: Int32) {
        events.append(.termination(pid: pid, wasCancelled: Task.isCancelled))
    }

    func recordTeardown() {
        events.append(.teardown)
    }

    func snapshot() -> [MoshDisconnectCleanupEvent] {
        events
    }
}

private actor MoshTerminationExecutor {
    struct Invocation: Sendable {
        let command: String
        let timeout: Duration
    }

    private var results: [Result<String, MoshCleanupTestError>]
    private var invocations: [Invocation] = []

    init(error: MoshCleanupTestError? = nil) {
        results = error.map { [.failure($0)] } ?? []
    }

    init(results: [Result<String, MoshCleanupTestError>]) {
        self.results = results
    }

    func execute(command: String, timeout: Duration) throws -> String {
        invocations.append(Invocation(command: command, timeout: timeout))
        guard !results.isEmpty else { return "" }
        return try results.removeFirst().get()
    }

    func snapshot() -> [Invocation] {
        invocations
    }
}
