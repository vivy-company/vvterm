import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct SSHStartupIntegrationTests {
    private final class ShellStartupBarrier: @unchecked Sendable {
        private let targetStage: SSHSession.ShellStartupStage
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var observedSessionIsBlocking: Bool?

        init(stage: SSHSession.ShellStartupStage) {
            targetStage = stage
        }

        func handle(_ event: SSHSession.ShellStartupTestEvent) {
            guard event.stage == targetStage else { return }
            let shouldWait = lock.withLock { () -> Bool in
                guard observedSessionIsBlocking == nil else { return false }
                observedSessionIsBlocking = event.sessionIsBlocking
                return true
            }
            guard shouldWait else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }

        func waitUntilEntered() -> Bool {
            entered.wait(timeout: .now() + 10) == .success
        }

        func resume() {
            release.signal()
        }

        var sessionWasBlocking: Bool? {
            lock.withLock { observedSessionIsBlocking }
        }
    }

    private struct Configuration {
        let host: String
        let port: Int
        let username: String
        let privateKey: Data

        static func fromEnvironment() throws -> Configuration? {
            let environment = ProcessInfo.processInfo.environment
            guard environment["VVTERM_SSH_INTEGRATION"] == "1" else { return nil }
            guard let encodedKey = environment["VVTERM_SSH_PRIVATE_KEY_BASE64"] else {
                throw IntegrationError.missingEnvironment("VVTERM_SSH_PRIVATE_KEY_BASE64")
            }
            guard let privateKey = Data(base64Encoded: encodedKey) else {
                throw IntegrationError.invalidPrivateKey
            }
            guard let port = Int(environment["VVTERM_SSH_PORT"] ?? "22"),
                  (1...65_535).contains(port) else {
                throw IntegrationError.invalidPort
            }
            return Configuration(
                host: environment["VVTERM_SSH_HOST"] ?? "127.0.0.1",
                port: port,
                username: environment["VVTERM_SSH_USERNAME"] ?? "vvterm",
                privateKey: privateKey
            )
        }

        func withPort(_ port: Int) -> Configuration {
            Configuration(host: host, port: port, username: username, privateKey: privateKey)
        }
    }

    private struct StartupResult {
        let transport: ShellTransport
        let fallbackReason: MoshFallbackReason?
        let elapsedMilliseconds: Int
    }

    private enum IntegrationError: Error {
        case invalidPort
        case invalidPrivateKey
        case missingEnvironment(String)
        case noTerminalData
    }

    private func makeIntegrationSSHClient() -> SSHClient {
        SSHClient.testing(
            hostKeyVerifier: KnownHostsManager.shared,
            moshBootstrap: RemoteMoshManager.shared
        )
    }

    @Test
    func sshAndMoshReachFirstTerminalByte() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }

        let ssh = try await measureStartups(
            count: 6,
            configuration: configuration,
            mode: .standard
        )
        reportBenchmark(name: "ssh", results: ssh)
        #expect(ssh.allSatisfy { $0.transport == .ssh })

        let mosh = try await measureStartups(
            count: 6,
            configuration: configuration,
            mode: .mosh
        )
        reportBenchmark(name: "mosh", results: mosh)
        #expect(mosh.allSatisfy { $0.transport == .mosh })
    }

    @Test
    func missingMoshServerFallsBackWithExactReason() async throws {
        guard let configuration = try Configuration.fromEnvironment(),
              let port = integrationPort(named: "VVTERM_SSH_MISSING_MOSH_PORT") else { return }

        let result = try await measureStartup(
            configuration: configuration.withPort(port),
            mode: .mosh
        )
        #expect(result.transport == .sshFallback)
        #expect(result.fallbackReason == .serverMissing)
    }

    @Test
    func blockedMoshUDPFallsBackWithExactReason() async throws {
        guard let configuration = try Configuration.fromEnvironment(),
              let port = integrationPort(named: "VVTERM_SSH_BLOCKED_UDP_PORT") else { return }

        let result = try await measureStartup(
            configuration: configuration.withPort(port),
            mode: .mosh
        )
        #expect(result.transport == .sshFallback)
        #expect(result.fallbackReason == .udpTimeout)
    }

    @Test @MainActor
    func managedTmuxCreateAndQuietReattachStayOnMosh() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }
        let previousKnownHost = KnownHostsManager.shared.entry(
            for: configuration.host,
            port: configuration.port
        )
        defer {
            restoreKnownHost(
                previousKnownHost,
                host: configuration.host,
                port: configuration.port
            )
        }

        let server = Server(
            workspaceId: UUID(),
            name: "DEV-223 integration",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            connectionMode: .mosh,
            authMethod: .sshKey
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            privateKey: configuration.privateKey
        )
        let client = makeIntegrationSSHClient()
        let sessionName = "vvterm_dev223_\(UUID().uuidString.lowercased())"

        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let createCommand = RemoteTmuxCommandBuilder.attachCommand(
                themeStyle: deterministicRemoteTmuxThemeStyle,
                sessionName: sessionName,
                workingDirectory: "~",
                lifecycleMarkerToken: UUID().uuidString
            )
            let created = try await client.startShell(
                cols: 80,
                rows: 24,
                startupCommand: createCommand
            )
            try #require(created.transport == .mosh)
            try await awaitFirstData(from: created.stream)
            try await awaitTmuxSession(named: sessionName, using: client)

            let target = "=\(sessionName):"
            let quietCommand = RemoteTerminalBootstrap.shellQuoted("sleep 30")
            let respawnMarker = "__VVTERM_DEV223_RESPAWNED__"
            let respawnOutput = try await client.execute(
                "\(RemoteTerminalBootstrap.shellPathExport()); tmux respawn-pane -k -t \(target) \(quietCommand) && printf %s \(respawnMarker)"
            )
            try #require(respawnOutput.contains(respawnMarker))

            let detachMarker = "__VVTERM_DEV223_DETACHED__"
            let detachOutput = try await client.execute(
                "\(RemoteTerminalBootstrap.shellPathExport()); tmux detach-client -s =\(sessionName) && printf %s \(detachMarker)"
            )
            try #require(detachOutput.contains(detachMarker))
            await client.closeShell(created.id)

            let reattachCommand = RemoteTmuxCommandBuilder.attachExistingCommand(
                themeStyle: deterministicRemoteTmuxThemeStyle,
                sessionName: sessionName,
                ownership: .managed,
                lifecycleMarkerToken: UUID().uuidString
            )
            let reattached = try await client.startShell(
                cols: 80,
                rows: 24,
                startupCommand: reattachCommand
            )
            try #require(reattached.transport == .mosh)

            await cleanupTmuxSession(named: sessionName, using: client)
            await client.closeShell(reattached.id)
            await client.disconnect()
        } catch {
            await cleanupTmuxSession(named: sessionName, using: client)
            await client.disconnect()
            throw error
        }
    }

    @Test @MainActor
    func managedTmuxCreateAndReattachStayAliveOnStandardSSH() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }
        let previousKnownHost = KnownHostsManager.shared.entry(
            for: configuration.host,
            port: configuration.port
        )
        defer {
            restoreKnownHost(
                previousKnownHost,
                host: configuration.host,
                port: configuration.port
            )
        }

        let client = makeIntegrationSSHClient()
        let (server, credentials) = makeStandardConnection(configuration: configuration)
        let sessionName = "vvterm_dev239_\(UUID().uuidString.lowercased())"

        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let createCommand = RemoteTmuxCommandBuilder.attachCommand(
                themeStyle: deterministicRemoteTmuxThemeStyle,
                sessionName: sessionName,
                workingDirectory: "~",
                lifecycleMarkerToken: UUID().uuidString
            )
            let shell = try await client.startShell(
                cols: 80,
                rows: 24,
                startupCommand: createCommand
            )
            try #require(shell.transport == .ssh)
            try await awaitFirstData(from: shell.stream)
            try await awaitTmuxSession(named: sessionName, using: client)

            try await Task.sleep(for: .milliseconds(750))
            let paneMarker = "__VVTERM_DEV239_PANE__"
            let paneState = try await client.execute(
                "\(RemoteTerminalBootstrap.shellPathExport()); tmux list-panes -t =\(sessionName): -F '#{pane_dead}:#{pane_current_command}' && printf %s \(paneMarker)"
            )
            let createdPaneStates = tmuxPaneStates(in: paneState, before: paneMarker)
            #expect(!createdPaneStates.isEmpty)
            #expect(createdPaneStates.allSatisfy { $0.split(separator: ":", maxSplits: 1).first == "0" })
            #expect(paneState.contains(paneMarker))

            let detachMarker = "__VVTERM_DEV239_DETACHED__"
            let detachOutput = try await client.execute(
                "\(RemoteTerminalBootstrap.shellPathExport()); tmux detach-client -s =\(sessionName) && printf %s \(detachMarker)"
            )
            try #require(detachOutput.contains(detachMarker))
            await client.closeShell(shell.id)

            let reattachCommand = RemoteTmuxCommandBuilder.attachExistingCommand(
                themeStyle: deterministicRemoteTmuxThemeStyle,
                sessionName: sessionName,
                ownership: .managed,
                lifecycleMarkerToken: UUID().uuidString
            )
            let reattached = try await client.startShell(
                cols: 80,
                rows: 24,
                startupCommand: reattachCommand
            )
            try #require(reattached.transport == .ssh)
            try await awaitFirstData(from: reattached.stream)
            try await Task.sleep(for: .milliseconds(750))

            let reattachPaneMarker = "__VVTERM_DEV239_REATTACHED_PANE__"
            let reattachedPaneState = try await client.execute(
                "\(RemoteTerminalBootstrap.shellPathExport()); tmux list-panes -t =\(sessionName): -F '#{pane_dead}:#{pane_current_command}' && printf %s \(reattachPaneMarker)"
            )
            let reattachedPaneStates = tmuxPaneStates(
                in: reattachedPaneState,
                before: reattachPaneMarker
            )
            #expect(!reattachedPaneStates.isEmpty)
            #expect(reattachedPaneStates.allSatisfy { $0.split(separator: ":", maxSplits: 1).first == "0" })
            #expect(reattachedPaneState.contains(reattachPaneMarker))

            _ = try await client.execute(
                "\(RemoteTerminalBootstrap.shellPathExport()); tmux detach-client -s =\(sessionName)"
            )
            await client.closeShell(reattached.id)
            await cleanupTmuxSession(named: sessionName, using: client)
            await client.disconnect()
        } catch {
            await cleanupTmuxSession(named: sessionName, using: client)
            await client.disconnect()
            throw error
        }
    }

    @Test
    func cancellingAtEachStartupBoundaryStopsStartupAndAllowsFreshConnection() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }
        let previousKnownHost = KnownHostsManager.shared.entry(
            for: configuration.host,
            port: configuration.port
        )
        defer {
            restoreKnownHost(
                previousKnownHost,
                host: configuration.host,
                port: configuration.port
            )
        }

        for testCase in shellStartupCases {
            let stage = testCase.stage
            let client = makeIntegrationSSHClient()
            let (server, credentials) = makeStandardConnection(configuration: configuration)
            let session = try await client.connect(to: server, credentials: credentials)
            let barrier = ShellStartupBarrier(stage: stage)
            await session.setShellStartupTestHook { event in
                barrier.handle(event)
            }

            let startup = Task {
                try await client.startShell(
                    cols: 80,
                    rows: 24,
                    startupCommand: testCase.startupCommand
                )
            }

            guard barrier.waitUntilEntered() else {
                startup.cancel()
                barrier.resume()
                await client.disconnect()
                Issue.record("Shell startup did not reach the \(stage) boundary")
                continue
            }

            startup.cancel()
            barrier.resume()

            do {
                let shell = try await startup.value
                await client.closeShell(shell.id)
                Issue.record("Cancelled \(stage) startup returned a live shell")
            } catch is CancellationError {
                // Expected controlled cancellation.
            } catch {
                Issue.record("Cancelled \(stage) startup returned unexpected error: \(error)")
            }

            #expect(barrier.sessionWasBlocking == false)
            #expect(await client.isConnected == false)
            await session.setShellStartupTestHook(nil)
            await client.disconnect()

            _ = try await client.connect(to: server, credentials: credentials)
            let replacement = try await client.startShell(cols: 80, rows: 24)
            await client.closeShell(replacement.id)
            await client.disconnect()
        }
    }

    @Test
    func disconnectingAtEachStartupBoundaryFailsCleanly() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }
        let previousKnownHost = KnownHostsManager.shared.entry(
            for: configuration.host,
            port: configuration.port
        )
        defer {
            restoreKnownHost(
                previousKnownHost,
                host: configuration.host,
                port: configuration.port
            )
        }

        for testCase in shellStartupCases {
            let stage = testCase.stage
            let client = makeIntegrationSSHClient()
            let (server, credentials) = makeStandardConnection(configuration: configuration)
            let session = try await client.connect(to: server, credentials: credentials)
            let barrier = ShellStartupBarrier(stage: stage)
            await session.setShellStartupTestHook { event in
                barrier.handle(event)
            }

            let startup = Task {
                try await client.startShell(
                    cols: 80,
                    rows: 24,
                    startupCommand: testCase.startupCommand
                )
            }

            guard barrier.waitUntilEntered() else {
                startup.cancel()
                barrier.resume()
                await client.disconnect()
                Issue.record("Shell startup did not reach the \(stage) boundary")
                continue
            }

            let disconnect = Task {
                await client.disconnect()
            }
            for _ in 0..<1_000 {
                if await client.isAborted { break }
                await Task.yield()
            }
            #expect(await client.isAborted)
            barrier.resume()

            do {
                let shell = try await startup.value
                await client.closeShell(shell.id)
                Issue.record("Disconnected \(stage) startup returned a live shell")
            } catch SSHError.notConnected {
                // Expected controlled transport invalidation.
            } catch {
                Issue.record("Disconnected \(stage) startup returned unexpected error: \(error)")
            }

            #expect(barrier.sessionWasBlocking == false)
            await session.setShellStartupTestHook(nil)
            await disconnect.value

            _ = try await client.connect(to: server, credentials: credentials)
            let replacement = try await client.startShell(cols: 80, rows: 24)
            await client.closeShell(replacement.id)
            await client.disconnect()
        }
    }

    @Test
    func rejectedPTYCleansChannelAndLeavesSessionUsable() async throws {
        guard let configuration = try Configuration.fromEnvironment(),
              let rejectedPTYPort = integrationPort(named: "VVTERM_SSH_REJECT_PTY_PORT") else { return }

        let rejectedConfiguration = configuration.withPort(rejectedPTYPort)
        let previousKnownHost = KnownHostsManager.shared.entry(
            for: rejectedConfiguration.host,
            port: rejectedConfiguration.port
        )
        defer {
            restoreKnownHost(
                previousKnownHost,
                host: rejectedConfiguration.host,
                port: rejectedConfiguration.port
            )
        }

        let client = makeIntegrationSSHClient()
        let (server, credentials) = makeStandardConnection(configuration: rejectedConfiguration)
        do {
            let session = try await client.connect(to: server, credentials: credentials)
            do {
                let shell = try await client.startShell(cols: 80, rows: 24)
                await client.closeShell(shell.id)
                Issue.record("PTY-rejecting server returned a live shell")
            } catch SSHError.shellRequestFailed {
                // Expected server rejection.
            } catch {
                Issue.record("PTY-rejecting server returned unexpected error: \(error)")
            }

            #expect(await session.discardedShellStartupChannelsForTesting() == 1)
            let output = try await client.execute("printf '__VVTERM_DEV201_CHANNEL_OK__'")
            #expect(output == "__VVTERM_DEV201_CHANNEL_OK__")
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    @Test
    func disconnectedTmuxProbeIsIndeterminateAndFreshConnectionRecovers() async throws {
        guard let configuration = try Configuration.fromEnvironment() else { return }
        let previousKnownHost = KnownHostsManager.shared.entry(
            for: configuration.host,
            port: configuration.port
        )
        defer {
            restoreKnownHost(
                previousKnownHost,
                host: configuration.host,
                port: configuration.port
            )
        }

        let staleClient = makeIntegrationSSHClient()
        let replacementClient = makeIntegrationSSHClient()
        let (server, credentials) = makeStandardConnection(configuration: configuration)

        do {
            _ = try await staleClient.connect(to: server, credentials: credentials)
            let initialAvailability = await RemoteTmuxManager.shared.tmuxAvailability(
                using: staleClient
            )
            #expect(initialAvailability == .available(.unixTmux))

            await staleClient.disconnect()
            let staleAvailability = await RemoteTmuxManager.shared.tmuxAvailability(
                using: staleClient
            )
            #expect(staleAvailability == .indeterminate(.disconnected))

            _ = try await replacementClient.connect(to: server, credentials: credentials)
            let recoveredAvailability = await RemoteTmuxManager.shared.tmuxAvailability(
                using: replacementClient
            )
            #expect(recoveredAvailability == .available(.unixTmux))
            await replacementClient.disconnect()
        } catch {
            await staleClient.disconnect()
            await replacementClient.disconnect()
            throw error
        }
    }

    private var shellStartupCases: [(
        stage: SSHSession.ShellStartupStage,
        startupCommand: String?
    )] {
        [
            (.channelOpenRetry, nil),
            (.ptyRequest, nil),
            (.shellRequest, nil),
            (.shellRequest, "exec /bin/sh"),
        ]
    }

    private func restoreKnownHost(
        _ entry: KnownHostsManager.Entry?,
        host: String,
        port: Int
    ) {
        if let entry {
            KnownHostsManager.shared.save(entry: entry)
        } else {
            KnownHostsManager.shared.remove(host: host, port: port)
        }
    }

    private func makeStandardConnection(
        configuration: Configuration
    ) -> (Server, ServerCredentials) {
        let server = Server(
            workspaceId: UUID(),
            name: "SSH integration",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            connectionMode: .standard,
            authMethod: .sshKey
        )
        return (
            server,
            ServerCredentials(serverId: server.id, privateKey: configuration.privateKey)
        )
    }

    private func measureStartup(
        configuration: Configuration,
        mode: SSHConnectionMode
    ) async throws -> StartupResult {
        let server = Server(
            workspaceId: UUID(),
            name: "DEV-209 integration",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            connectionMode: mode,
            authMethod: .sshKey
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            privateKey: configuration.privateKey
        )
        let client = makeIntegrationSSHClient()
        let startedAt = ContinuousClock.now

        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let shell = try await client.startShell(
                cols: 80,
                rows: 24,
                startupCommand: "printf '__VVTERM_DEV209_READY__\\n'; exec /bin/sh -l"
            )
            try await awaitFirstData(from: shell.stream)
            let elapsed = milliseconds(startedAt.duration(to: .now))
            await client.disconnect()
            return StartupResult(
                transport: shell.transport,
                fallbackReason: shell.fallbackReason,
                elapsedMilliseconds: elapsed
            )
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func measureStartups(
        count: Int,
        configuration: Configuration,
        mode: SSHConnectionMode
    ) async throws -> [StartupResult] {
        var results: [StartupResult] = []
        results.reserveCapacity(count)
        for _ in 0..<count {
            results.append(
                try await measureStartup(configuration: configuration, mode: mode)
            )
        }
        return results
    }

    private func reportBenchmark(name: String, results: [StartupResult]) {
        guard let cold = results.first else { return }
        let warm = results.dropFirst().map(\.elapsedMilliseconds).sorted()
        guard let slowTail = warm.last else { return }
        let median = warm[warm.count / 2]
        print(
            "DEV209 benchmark transport=\(name) coldMs=\(cold.elapsedMilliseconds) warmMedianMs=\(median) warmSlowTailMs=\(slowTail)"
        )
    }

    private func awaitFirstData(from stream: TerminalOutputStream) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in stream where !data.isEmpty {
                    return
                }
                throw IntegrationError.noTerminalData
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw SSHError.timeout
            }
            guard try await group.next() != nil else {
                throw IntegrationError.noTerminalData
            }
            group.cancelAll()
        }
    }

    private func awaitTmuxSession(
        named sessionName: String,
        using client: SSHClient
    ) async throws {
        let existsMarker = "__VVTERM_DEV223_TMUX_EXISTS__"
        let probe = "\(RemoteTerminalBootstrap.shellPathExport()); tmux has-session -t =\(sessionName) 2>/dev/null && printf %s \(existsMarker)"
        for _ in 0..<100 {
            let output = try? await client.execute(probe, timeout: .seconds(1))
            if output?.contains(existsMarker) == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SSHError.timeout
    }

    private func tmuxPaneStates(in output: String, before marker: String) -> [String] {
        let paneOutput = output.components(separatedBy: marker).first ?? output
        return paneOutput
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func cleanupTmuxSession(named sessionName: String, using client: SSHClient) async {
        _ = try? await client.execute(
            "\(RemoteTerminalBootstrap.shellPathExport()); tmux kill-session -t =\(sessionName) 2>/dev/null"
        )
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded)
    }

    private func integrationPort(named name: String) -> Int? {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let port = Int(rawValue),
              (1...65_535).contains(port) else { return nil }
        return port
    }
}
