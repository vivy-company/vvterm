import Foundation
import os.log

nonisolated enum EternalTerminalStatePolicy {
    static func connectionState(
        for state: EternalTerminalSessionState,
        host: String,
        port: Int
    ) -> ConnectionState? {
        switch state {
        case .idle:
            return nil
        case .bootstrapping, .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnected, .reconnecting:
            // swift-et owns recovery. Publishing `.disconnected` here would make
            // VVTerm replace a session that is already reconnecting itself.
            return .reconnecting(attempt: 1)
        case .failed(let error):
            return .failed(.eternalTerminal(
                failure: error,
                host: host,
                port: port
            ))
        case .closed:
            return .disconnected
        }
    }
}

nonisolated enum EternalTerminalFailureAnalytics {
    static func analyticsCategory(for failure: EternalTerminalSessionFailure) -> String {
        switch failure {
        case .bootstrapSSH, .bootstrapResponse, .malformedBootstrapCredentials:
            return "bootstrap"
        case .transport: return "network"
        case .invalidKey: return "authentication"
        case .protocolMismatch: return "protocol"
        case .disconnectedBufferFull: return "buffer"
        case .connectionInProgress, .connectionClosed, .applicationSuspended: return "lifecycle"
        case .sessionUnrecoverable: return "recovery"
        case .client: return "client"
        case .resumeState, .unknown: return "unknown"
        }
    }
}

nonisolated enum EternalTerminalStartupCommand {
    static func remoteScriptPath(token: UUID) -> String {
        "/tmp/vvterm-et-start-\(token.uuidString.lowercased()).sh"
    }

    static func script(command: String, remotePath: String) -> String {
        """
        rm -f -- \(RemoteTerminalBootstrap.shellQuoted(remotePath))
        \(command)
        """
    }

    static func invocation(remotePath: String) -> String {
        "/bin/sh \(RemoteTerminalBootstrap.shellQuoted(remotePath))"
    }
}

nonisolated enum EternalTerminalResumePolicy {
    static func shouldDiscardCredentials(
        after failure: EternalTerminalSessionFailure
    ) -> Bool {
        return switch failure {
        case .invalidKey, .connectionClosed, .sessionUnrecoverable:
            true
        case .resumeState(_, let discardStoredState):
            discardStoredState
        case .bootstrapSSH, .bootstrapResponse, .malformedBootstrapCredentials,
             .transport, .protocolMismatch, .disconnectedBufferFull,
             .connectionInProgress, .applicationSuspended, .client, .unknown:
            false
        }
    }
}

nonisolated struct EternalTerminalRecoveryProbe {
    private enum State: Equatable, Sendable {
        case idle
        case pending(UUID)
        case completed(UUID)
    }

    private var state = State.idle

    mutating func begin() -> UUID {
        let id = UUID()
        state = .pending(id)
        return id
    }

    var pendingID: UUID? {
        guard case .pending(let id) = state else { return nil }
        return id
    }

    mutating func recordConnected(eventProbeID: UUID?) {
        guard case .pending(let pendingID) = state,
              eventProbeID == pendingID else { return }
        state = .completed(pendingID)
    }

    func didComplete(_ id: UUID) -> Bool {
        state == .completed(id)
    }

    mutating func reset() {
        state = .idle
    }
}

@MainActor
struct EternalTerminalRuntimeOwnerAccess {
    let isCurrent: @MainActor @Sendable (_ paneId: UUID, _ runtimeToken: UUID) -> Bool
    let startupPlan: @MainActor @Sendable (
        _ paneId: UUID,
        _ serverId: UUID,
        _ client: SSHClient,
        _ runtimeToken: UUID
    ) async throws -> TerminalShellStartupPlan
    let resumeContext: @MainActor @Sendable (UUID) -> EternalTerminalTmuxResumeContext?
    let setResumeContext: @MainActor @Sendable (UUID, EternalTerminalTmuxResumeContext?) -> Void
    let updateConnectionState: @MainActor @Sendable (UUID, ConnectionState) -> Void
    let markEternalTerminalTransport: @MainActor @Sendable (UUID) -> Void
    let handleShellEnd: @MainActor @Sendable (UUID, UUID, TerminalShellEndReason) -> Void
    let unregister: @MainActor @Sendable (UUID, UUID) async -> Void
}

@MainActor
final class EternalTerminalRuntime {
    private struct ConnectedStateWork {
        let recoveryProbeID: UUID?
        let cols: Int
        let rows: Int
        let pixelSize: TerminalPixelSize?
    }

    let paneId: UUID
    let identityToken = UUID()

    private let server: Server
    private let sessionRequest: EternalTerminalSessionRequest
    private let dependencies: EternalTerminalRuntimeDependencies
    private let ownerAccess: EternalTerminalRuntimeOwnerAccess
    private var session: (any EternalTerminalSession)?
    private weak var outputSink: (any TerminalOutputSink)?
    private var outputTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var connectAttemptID: UUID?
    private var reconnectEventActive = false
    private var failureReported = false
    private var networkRecoveryProbe = EternalTerminalRecoveryProbe()
    private var startupApplied = false
    private var tmuxLifecycle: EternalTerminalTmuxResumeContext?
    private var tmuxLifecycleParser: TmuxLifecycleStreamParser?
    private var lastTerminalSize: (cols: Int, rows: Int, pixels: TerminalPixelSize?) = (0, 0, nil)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "EternalTerminal"
    )

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        ownerAccess: EternalTerminalRuntimeOwnerAccess,
        dependencies: EternalTerminalRuntimeDependencies
    ) {
        self.paneId = paneId
        self.server = server
        self.ownerAccess = ownerAccess
        self.dependencies = dependencies
        sessionRequest = EternalTerminalSessionRequest(
            paneId: paneId,
            server: server,
            credentials: credentials
        )
    }

    var isStartInFlight: Bool { connectTask != nil }

    private var isCurrentOwner: Bool {
        ownerAccess.isCurrent(paneId, identityToken)
    }

    func abortConnection() {
        outputSink = nil
        networkRecoveryProbe.reset()
        if let session = detachActiveSession() {
            Task { await session.close() }
        }
    }

    func attach(to outputSink: any TerminalOutputSink) {
        self.outputSink = outputSink
    }

    func startIfNeeded() {
        guard connectTask == nil, stateTask == nil else { return }

        let attemptID = UUID()
        let paneId = paneId
        let serverId = server.id
        let host = server.host
        let port = server.eternalTerminalPort
        let runtimeToken = identityToken
        let sessionRequest = sessionRequest
        let dependencies = dependencies
        let ownerAccess = ownerAccess

        dependencies.record(.connectionAttempted)
        connectAttemptID = attemptID
        connectTask = Task { [weak self] in
            do {
                let prepared = try await dependencies.sessionPreparer.prepareSession(
                    request: sessionRequest,
                    startupPlanProvider: { client in
                        try await ownerAccess.startupPlan(
                            paneId,
                            serverId,
                            client,
                            runtimeToken
                        )
                    },
                    isCurrentOwner: {
                        ownerAccess.isCurrent(paneId, runtimeToken)
                    }
                )
                guard !Task.isCancelled,
                      self?.acceptPreparedSession(
                        prepared,
                        attemptID: attemptID,
                        host: host,
                        port: port
                      ) == true else {
                    await prepared.session.close()
                    return
                }
                try await prepared.session.connect()
                guard ownerAccess.isCurrent(paneId, runtimeToken),
                      self?.ownsConnectAttempt(
                        attemptID
                      ) == true else { return }
                try? await prepared.session.persistCheckpoint {
                    ownerAccess.isCurrent(paneId, runtimeToken)
                }
            } catch is CancellationError {
                // The accepted session is closed by the owner that detached it.
            } catch {
                self?.publishFailure(
                    error,
                    forConnectAttempt: attemptID,
                    host: host,
                    port: port
                )
            }
            self?.finishConnectAttempt(attemptID)
        }

        ownerAccess.markEternalTerminalTransport(paneId)
    }

    func send(_ data: Data) {
        guard let session else { return }
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.send(data)
            } catch {
                logger.warning("Failed to send ET input: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func sendInteractiveScript(_ script: String) async throws {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        guard let session else { throw EternalTerminalSessionFailure.connectionClosed }
        try await session.send(data)
    }

    func withBootstrapSSHClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        guard let session else { throw EternalTerminalSessionFailure.connectionClosed }
        return try await session.withBootstrapSSHClient(operation)
    }

    func killManagedTmuxSession(named sessionName: String) async {
        do {
            try await withBootstrapSSHClient { [dependencies] client in
                await dependencies.killTmuxSession(
                    named: sessionName,
                    using: client
                )
            }
        } catch {
            logger.warning("Failed to clean up ET tmux session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        guard cols > 0, rows > 0 else { return }
        guard cols != lastTerminalSize.cols
                || rows != lastTerminalSize.rows
                || pixelSize != lastTerminalSize.pixels else { return }
        lastTerminalSize = (cols, rows, pixelSize)
        guard let session else { return }
        Task(priority: .userInitiated) { [logger] in
            do {
                try await session.resize(
                    rows: rows,
                    cols: cols,
                    pixelWidth: pixelSize?.width,
                    pixelHeight: pixelSize?.height
                )
            } catch {
                logger.debug("Failed to send ET terminal size: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func beginNetworkRecoveryProbe() async -> UUID? {
        guard let session,
              isCurrentOwner else {
            return nil
        }
        let probeID = networkRecoveryProbe.begin()
        await session.notifyNetworkPathChanged()
        guard isCurrentOwner else {
            return nil
        }
        return probeID
    }

    func notifyNetworkPathChanged() async {
        await session?.notifyNetworkPathChanged()
    }

    func completedNetworkRecoveryProbe(_ probeID: UUID) -> Bool {
        isCurrentOwner && networkRecoveryProbe.didComplete(probeID)
    }

    func persistCheckpoint() async {
        guard let session else { return }
        do {
            try await session.persistCheckpoint { [weak self] in
                self?.isCurrentOwner == true
            }
        } catch EternalTerminalSessionFailure.connectionClosed {
            return
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Failed to save ET recovery checkpoint: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepareForApplicationBackground() async {
        guard let session else { return }
        do {
            try await session.prepareForApplicationBackground { [weak self] in
                self?.isCurrentOwner == true
            }
        } catch EternalTerminalSessionFailure.connectionClosed {
            return
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Failed to save ET background checkpoint: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeFromApplicationBackground() async {
        await session?.resumeFromApplicationBackground()
    }

    func close() async {
        let session = detachActiveSession()
        outputSink = nil
        await session?.close()
    }

    private func detachActiveSession() -> (any EternalTerminalSession)? {
        connectTask?.cancel()
        outputTask?.cancel()
        stateTask?.cancel()
        connectTask = nil
        connectAttemptID = nil
        outputTask = nil
        stateTask = nil
        networkRecoveryProbe.reset()
        let activeSession = session
        session = nil
        return activeSession
    }

    private func acceptPreparedSession(
        _ prepared: PreparedEternalTerminalSession,
        attemptID: UUID,
        host: String,
        port: Int
    ) -> Bool {
        guard connectAttemptID == attemptID, isCurrentOwner else { return false }
        session = prepared.session
        configureLifecycle(for: prepared.origin)
        observe(prepared.session, host: host, port: port)
        return true
    }

    private func ownsConnectAttempt(
        _ attemptID: UUID
    ) -> Bool {
        connectAttemptID == attemptID
            && session != nil
            && isCurrentOwner
    }

    private func finishConnectAttempt(_ attemptID: UUID) {
        guard connectAttemptID == attemptID else { return }
        connectAttemptID = nil
        connectTask = nil
    }

    private func publishFailure(
        _ error: Error,
        forConnectAttempt attemptID: UUID,
        host: String,
        port: Int
    ) {
        guard connectAttemptID == attemptID else { return }
        publishFailure(error, host: host, port: port)
    }

    private func observe(
        _ session: any EternalTerminalSession,
        host: String,
        port: Int
    ) {
        outputTask = Task { [weak self] in
            for await data in session.output {
                guard !Task.isCancelled else { return }
                self?.consumeOutput(data)
            }
        }

        stateTask = Task { [weak self] in
            for await state in session.stateChanges {
                guard !Task.isCancelled else { return }
                guard let work = self?.beginHandling(
                    state,
                    host: host,
                    port: port
                ) else { continue }
                do {
                    try await session.resize(
                        rows: work.rows,
                        cols: work.cols,
                        pixelWidth: work.pixelSize?.width,
                        pixelHeight: work.pixelSize?.height
                    )
                    self?.finishConnectedState(work)
                } catch {
                    self?.publishFailure(error, host: host, port: port)
                }
            }
        }
    }

    private func configureLifecycle(for origin: EternalTerminalSessionOrigin) {
        guard origin == .resumed else { return }
        startupApplied = true
        let context = ownerAccess.resumeContext(paneId)
        tmuxLifecycle = context
        tmuxLifecycleParser = context.map {
            TmuxLifecycleStreamParser(markerToken: $0.markerToken)
        }
    }

    private func beginHandling(
        _ state: EternalTerminalSessionState,
        host: String,
        port: Int
    ) -> ConnectedStateWork? {
        guard isCurrentOwner else {
            return nil
        }
        let recoveryProbeIDAtEvent = networkRecoveryProbe.pendingID
        if state == .reconnecting || state == .disconnected {
            if !reconnectEventActive {
                reconnectEventActive = true
                dependencies.record(.connectionReconnecting)
            }
        } else if state == .connected {
            reconnectEventActive = false
            guard lastTerminalSize.cols > 0, lastTerminalSize.rows > 0 else {
                logger.error("ET connected without a valid terminal grid")
                return nil
            }
            return ConnectedStateWork(
                recoveryProbeID: recoveryProbeIDAtEvent,
                cols: lastTerminalSize.cols,
                rows: lastTerminalSize.rows,
                pixelSize: lastTerminalSize.pixels
            )
        }

        if case .failed(let error) = state {
            publishFailure(error, host: host, port: port)
            return nil
        }

        guard let connectionState = EternalTerminalStatePolicy.connectionState(
            for: state,
            host: host,
            port: port
        ) else { return nil }
        guard isCurrentOwner else {
            return nil
        }
        ownerAccess.updateConnectionState(paneId, connectionState)
        ownerAccess.markEternalTerminalTransport(paneId)
        return nil
    }

    private func finishConnectedState(_ work: ConnectedStateWork) {
        guard isCurrentOwner else { return }
        applyStartupPlanIfNeeded()
        networkRecoveryProbe.recordConnected(eventProbeID: work.recoveryProbeID)
        ownerAccess.updateConnectionState(paneId, .connected)
        ownerAccess.markEternalTerminalTransport(paneId)
    }

    private func applyStartupPlanIfNeeded() {
        guard !startupApplied else { return }
        startupApplied = true
        guard let session else { return }
        let host = server.host
        let port = server.eternalTerminalPort
        Task { [weak self] in
            let plan = await session.preparedStartupPlan()
            guard let data = self?.acceptStartupPlan(plan) else { return }
            do {
                try await session.send(data)
            } catch {
                self?.publishFailure(error, host: host, port: port)
            }
        }
    }

    private func acceptStartupPlan(_ plan: TerminalShellStartupPlan) -> Data? {
        guard isCurrentOwner else { return nil }
        let resumeContext = plan.tmuxLifecycle.map {
            EternalTerminalTmuxResumeContext(
                ownership: $0.ownership,
                markerToken: $0.markerToken
            )
        }
        tmuxLifecycle = resumeContext
        tmuxLifecycleParser = resumeContext.map {
            TmuxLifecycleStreamParser(markerToken: $0.markerToken)
        }
        ownerAccess.setResumeContext(paneId, resumeContext)
        guard let command = plan.command,
              let data = "\(command)\r".data(using: .utf8) else { return nil }
        return data
    }

    private func consumeOutput(_ data: Data) {
        guard isCurrentOwner else {
            return
        }
        guard var parser = tmuxLifecycleParser else {
            outputSink?.receiveTerminalOutput(data)
            return
        }
        let result = parser.consume(data)
        tmuxLifecycleParser = parser
        if !result.output.isEmpty {
            outputSink?.receiveTerminalOutput(result.output)
        }
        guard let event = result.events.last, let tmuxLifecycle else { return }
        let reason: TerminalShellEndReason
        switch event {
        case .detached:
            reason = .tmuxDetached(tmuxLifecycle.ownership)
        case .ended:
            reason = .tmuxEnded(tmuxLifecycle.ownership)
        case .creationFailed:
            reason = .tmuxCreationFailed
        }
        ownerAccess.handleShellEnd(paneId, identityToken, reason)
        let runtimeToken = identityToken
        let ownerAccess = ownerAccess
        Task {
            await ownerAccess.unregister(paneId, runtimeToken)
        }
    }

    private func publishFailure(_ error: Error, host: String, port: Int) {
        guard isCurrentOwner else {
            logger.info(
                "Ignoring failure from stale ET runtime for pane \(self.paneId.uuidString, privacy: .public)"
            )
            return
        }
        let failure = error as? EternalTerminalSessionFailure ?? .unknown
        if EternalTerminalResumePolicy.shouldDiscardCredentials(after: failure) {
            do {
                try dependencies.sessionPreparer.discardResumeState(for: paneId)
            } catch {
                logger.error("Failed to invalidate ET resume credentials: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !failureReported {
            failureReported = true
            dependencies.record(
                .connectionFailed(
                    reason: EternalTerminalFailureAnalytics.analyticsCategory(
                        for: failure
                    )
                )
            )
        }
        ownerAccess.updateConnectionState(
            paneId,
            .failed(.eternalTerminal(
                failure: failure,
                host: host,
                port: port
            ))
        )
        ownerAccess.markEternalTerminalTransport(paneId)
    }
}
