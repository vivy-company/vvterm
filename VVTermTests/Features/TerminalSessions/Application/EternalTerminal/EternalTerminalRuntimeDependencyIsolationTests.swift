import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class EternalTerminalEventRecorder {
    private(set) var events: [EternalTerminalRuntimeEvent] = []

    func record(_ event: EternalTerminalRuntimeEvent) {
        events.append(event)
    }
}

private actor EternalTerminalTmuxKillRecorder: EternalTerminalTmuxSessionKilling {
    private var sessionNames: [String] = []

    func killSession(named sessionName: String, using client: SSHClient) async {
        sessionNames.append(sessionName)
    }

    func recordedSessionNames() -> [String] {
        sessionNames
    }
}

private final class FailingEternalTerminalResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? {
        throw EternalTerminalResumeCredentialError.secureStorageUnavailable
    }

    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

@MainActor
private struct FailingEternalTerminalSessionPreparer: EternalTerminalSessionPreparing {
    func prepareSession(
        request: EternalTerminalSessionRequest,
        startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws -> PreparedEternalTerminalSession {
        throw EternalTerminalSessionFailure.resumeState(
            message: "Unavailable test session",
            discardStoredState: false
        )
    }

    func discardResumeState(for paneId: UUID) throws {}
}

private actor EternalTerminalConnectGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitIgnoringCancellation() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if continuations.count >= count { return true }
            await Task.yield()
        }
        return continuations.count >= count
    }

    func release(at index: Int) {
        continuations[index].resume()
    }
}

private actor BlockingEternalTerminalSession: EternalTerminalSession {
    nonisolated let output = AsyncStream<Data> { _ in }
    nonisolated let stateChanges = AsyncStream<EternalTerminalSessionState> { _ in }

    private let connectGate: EternalTerminalConnectGate
    private var closeCalls = 0

    init(connectGate: EternalTerminalConnectGate) {
        self.connectGate = connectGate
    }

    func connect() async throws {
        await connectGate.waitIgnoringCancellation()
    }

    func send(_ data: Data) async throws {}

    func resize(
        rows: Int,
        cols: Int,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) async throws {}

    func notifyNetworkPathChanged() async {}

    func persistCheckpoint(
        ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws {}

    func prepareForApplicationBackground(
        ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws {}

    func resumeFromApplicationBackground() async {}
    func preparedStartupPlan() async -> TerminalShellStartupPlan { .plainShell }

    func withBootstrapSSHClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        try await operation(SSHClient.testing())
    }

    func close() async {
        closeCalls += 1
    }

    func closeCount() -> Int { closeCalls }
}

@MainActor
private final class SequencedEternalTerminalSessionPreparer: EternalTerminalSessionPreparing {
    private let sessions: [BlockingEternalTerminalSession]
    private var nextIndex = 0

    init(sessions: [BlockingEternalTerminalSession]) {
        self.sessions = sessions
    }

    func prepareSession(
        request: EternalTerminalSessionRequest,
        startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws -> PreparedEternalTerminalSession {
        guard sessions.indices.contains(nextIndex) else { throw CancellationError() }
        let session = sessions[nextIndex]
        nextIndex += 1
        return PreparedEternalTerminalSession(session: session, origin: .bootstrapped)
    }

    func discardResumeState(for paneId: UUID) throws {}
}

@Suite(.serialized)
@MainActor
struct EternalTerminalRuntimeDependencyIsolationTests {
    @Test
    func cancelledConnectCannotClearReplacementOrCloseAnAcceptedSessionTwice() async {
        let gate = EternalTerminalConnectGate()
        let firstSession = BlockingEternalTerminalSession(connectGate: gate)
        let replacementSession = BlockingEternalTerminalSession(connectGate: gate)
        let events = EternalTerminalEventRecorder()
        let dependencies = EternalTerminalRuntimeDependencies(
            recordEvent: { [events] event in events.record(event) },
            tmuxSessionKiller: EternalTerminalTmuxKillRecorder(),
            sessionPreparer: SequencedEternalTerminalSessionPreparer(
                sessions: [firstSession, replacementSession]
            )
        )
        let runtime = makeRuntime(dependencies: dependencies)

        runtime.startIfNeeded()
        #expect(await gate.waitForCount(1))
        runtime.abortConnection()
        runtime.startIfNeeded()
        #expect(await gate.waitForCount(2))

        await gate.release(at: 0)
        for _ in 0..<20 { await Task.yield() }

        #expect(runtime.isStartInFlight)
        #expect(await firstSession.closeCount() == 1)

        await runtime.close()
        await gate.release(at: 1)
        for _ in 0..<20 { await Task.yield() }

        #expect(await firstSession.closeCount() == 1)
        #expect(await replacementSession.closeCount() == 1)
    }

    @Test
    func runtimesAndPortsKeepEffectsAndTmuxKillsWithTheirOwners() async {
        let firstEvents = EternalTerminalEventRecorder()
        let secondEvents = EternalTerminalEventRecorder()
        let firstTmux = EternalTerminalTmuxKillRecorder()
        let secondTmux = EternalTerminalTmuxKillRecorder()
        let firstDependencies = dependencies(events: firstEvents, tmux: firstTmux)
        let secondDependencies = dependencies(events: secondEvents, tmux: secondTmux)
        let firstRuntime = makeRuntime(
            dependencies: firstDependencies
        )
        let secondRuntime = makeRuntime(
            dependencies: secondDependencies
        )

        firstRuntime.startIfNeeded()
        firstRuntime.abortConnection()
        firstDependencies.record(.connectionReconnecting)
        firstDependencies.record(.connectionFailed(reason: "network"))
        await firstDependencies.killTmuxSession(
            named: "first-session",
            using: SSHClient.testing()
        )

        #expect(firstEvents.events == [
            .connectionAttempted,
            .connectionReconnecting,
            .connectionFailed(reason: "network")
        ])
        #expect(secondEvents.events.isEmpty)
        #expect(await firstTmux.recordedSessionNames() == ["first-session"])
        #expect(await secondTmux.recordedSessionNames().isEmpty)

        await firstRuntime.close()
        await secondRuntime.close()
    }

    private func dependencies(
        events: EternalTerminalEventRecorder,
        tmux: EternalTerminalTmuxKillRecorder
    ) -> EternalTerminalRuntimeDependencies {
        EternalTerminalRuntimeDependencies(
            recordEvent: { [events] event in
                events.record(event)
            },
            tmuxSessionKiller: tmux,
            sessionPreparer: FailingEternalTerminalSessionPreparer()
        )
    }

    private func makeRuntime(
        dependencies: EternalTerminalRuntimeDependencies
    ) -> EternalTerminalRuntime {
        let server = Server(
            workspaceId: UUID(),
            name: "Isolated ET",
            host: "example.invalid",
            username: "test"
        )
        return EternalTerminalRuntime(
            paneId: UUID(),
            server: server,
            credentials: ServerCredentials(serverId: server.id),
            ownerAccess: EternalTerminalRuntimeOwnerAccess(
                isCurrent: { _, _ in true },
                startupPlan: { _, _, _, _ in throw CancellationError() },
                resumeContext: { _ in nil },
                setResumeContext: { _, _ in },
                updateConnectionState: { _, _ in },
                markEternalTerminalTransport: { _ in },
                handleShellEnd: { _, _, _ in },
                unregister: { _, _ in }
            ),
            dependencies: dependencies
        )
    }
}
