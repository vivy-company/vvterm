import Foundation
import os.log
import Testing
@testable import VVTerm

private actor SSHConnectionRunnerTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async -> Bool {
        for _ in 0..<2_000 {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SSHConnectionRunnerTestRecorder {
    private var closeShellIds: [UUID] = []
    private var registrationCount = 0
    private var startSizes: [(columns: Int, rows: Int)] = []

    func recordClose(shellId: UUID) {
        closeShellIds.append(shellId)
    }

    func recordRegistration() {
        registrationCount += 1
    }

    func recordStart(columns: Int, rows: Int) {
        startSizes.append((columns, rows))
    }

    func closeCount(for shellId: UUID) -> Int {
        closeShellIds.reduce(into: 0) { count, closedShellId in
            if closedShellId == shellId {
                count += 1
            }
        }
    }

    func registrations() -> Int {
        registrationCount
    }

    func recordedStartSizes() -> [[Int]] {
        startSizes.map { [$0.columns, $0.rows] }
    }
}

@Suite(.serialized)
@MainActor
struct SSHConnectionRunnerTests {
    @Test
    func cancellationAfterShellOpenClosesUnregisteredShellExactlyOnce() async {
        let fixture = makeFixture()
        let gate = SSHConnectionRunnerTestGate()
        let recorder = SSHConnectionRunnerTestRecorder()
        let transport = makeTransport(
            shell: fixture.shell,
            recorder: recorder,
            startShell: { columns, rows in
                await recorder.recordStart(columns: columns, rows: rows)
                await gate.suspend()
            }
        )

        let task = Task {
            await run(
                fixture: fixture,
                transport: transport,
                registerShell: { _ in
                    await recorder.recordRegistration()
                    return true
                }
            )
        }

        #expect(await gate.waitUntilSuspended())
        task.cancel()
        await gate.resume()
        await task.value

        #expect(await recorder.recordedStartSizes() == [[132, 43]])
        #expect(await recorder.closeCount(for: fixture.shell.id) == 1)
        #expect(await recorder.registrations() == 0)
    }

    @Test
    func rejectedRegistrationLeavesShellCleanupToManagerOwner() async {
        let fixture = makeFixture()
        let recorder = SSHConnectionRunnerTestRecorder()
        let transport = makeTransport(
            shell: fixture.shell,
            recorder: recorder,
            startShell: { columns, rows in
                await recorder.recordStart(columns: columns, rows: rows)
            }
        )

        await run(
            fixture: fixture,
            transport: transport,
            registerShell: { _ in
                await recorder.recordRegistration()
                return false
            }
        )

        #expect(await recorder.recordedStartSizes() == [[132, 43]])
        #expect(await recorder.registrations() == 1)
        #expect(await recorder.closeCount(for: fixture.shell.id) == 0)
    }

    private struct Fixture {
        let server: Server
        let credentials: ServerCredentials
        let shell: ShellHandle
    }

    private func makeFixture() -> Fixture {
        let server = Server(
            workspaceId: UUID(),
            name: "Runner",
            host: "runner.example.invalid",
            username: "tester"
        )
        var credentials = ServerCredentials(serverId: server.id)
        credentials.credentialBinding = ServerCredentialBinding(server: server)
        let channel = TerminalOutputChannel()
        let shell = ShellHandle(
            id: UUID(),
            stream: TerminalOutputStream(channel: channel)
        )
        return Fixture(server: server, credentials: credentials, shell: shell)
    }

    private func makeTransport(
        shell: ShellHandle,
        recorder: SSHConnectionRunnerTestRecorder,
        startShell: @escaping @Sendable (_ columns: Int, _ rows: Int) async -> Void
    ) -> SSHConnectionRunnerTransport {
        SSHConnectionRunnerTransport(
            connect: { _, _ in },
            startShell: { columns, rows, _, _ in
                await startShell(columns, rows)
                return shell
            },
            disconnect: {},
            closeShell: { shellId in
                await recorder.recordClose(shellId: shellId)
            },
            execute: { _, _ in "" }
        )
    }

    private func run(
        fixture: Fixture,
        transport: SSHConnectionRunnerTransport,
        registerShell: @MainActor @escaping @Sendable (ShellHandle) async -> Bool
    ) async {
        await SSHConnectionRunner.run(
            server: fixture.server,
            credentials: fixture.credentials,
            transport: transport,
            initialTerminalState: SSHConnectionInitialTerminalState(
                columns: 132,
                rows: 43,
                pixelSize: nil
            ),
            logger: Logger(subsystem: "SSHConnectionRunnerTests", category: "Runner"),
            shouldContinueConnection: { true },
            onAttempt: { _ in },
            startupPlan: { .plainShell },
            restoreMoshShell: { _, _ in nil },
            registerShell: registerShell,
            onTitleChange: { _ in },
            writeOutput: { _ in true },
            shouldResetClient: { _ in false },
            onProcessExit: { _, _ in },
            onFailure: { error in
                Issue.record("Unexpected runner failure: \(error.localizedDescription)")
            }
        )
    }
}
