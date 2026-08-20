import Foundation

nonisolated enum EternalTerminalSessionState: Equatable, Sendable {
    case idle
    case bootstrapping
    case connecting
    case connected
    case disconnected
    case reconnecting
    case failed(EternalTerminalSessionFailure)
    case closed
}

nonisolated enum EternalTerminalSessionOrigin: Equatable, Sendable {
    case bootstrapped
    case resumed
}

nonisolated struct EternalTerminalSessionRequest: Sendable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
}

nonisolated struct PreparedEternalTerminalSession: Sendable {
    let session: any EternalTerminalSession
    let origin: EternalTerminalSessionOrigin
}

nonisolated protocol EternalTerminalSession: Sendable {
    var output: AsyncStream<Data> { get }
    var stateChanges: AsyncStream<EternalTerminalSessionState> { get }

    func connect() async throws
    func send(_ data: Data) async throws
    func resize(
        rows: Int,
        cols: Int,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) async throws
    func notifyNetworkPathChanged() async
    func persistCheckpoint(
        ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws
    func prepareForApplicationBackground(
        ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws
    func resumeFromApplicationBackground() async
    func preparedStartupPlan() async -> TerminalShellStartupPlan
    func withBootstrapSSHClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result
    func close() async
}

@MainActor
protocol EternalTerminalSessionPreparing: Sendable {
    func prepareSession(
        request: EternalTerminalSessionRequest,
        startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async throws -> PreparedEternalTerminalSession

    func discardResumeState(for paneId: UUID) throws
}

@MainActor
protocol TerminalOutputSink: AnyObject {
    func receiveTerminalOutput(_ data: Data)
}
