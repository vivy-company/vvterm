import Combine
import Foundation

nonisolated enum TerminalNetworkReadiness: String, Hashable, Sendable {
    case unknown
    case ready
    case unavailable
}

nonisolated protocol TerminalRemoteTmuxServicing: Sendable {
    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability
    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend?
    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession]
    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend?
    ) async
    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws
    func killSession(
        named sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async
    func cleanupLegacySessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async
    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async
    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async -> String?
}

nonisolated protocol TerminalRemoteMoshServicing: Sendable {
    func installMoshServer(using client: SSHClient) async throws
}

@MainActor
struct TerminalNetworkReadinessSource {
    let initial: TerminalNetworkReadiness
    let updates: AnyPublisher<TerminalNetworkReadiness, Never>
}

@MainActor
struct TerminalAppLockSource {
    let initialIsLocked: Bool
    let updates: AnyPublisher<Bool, Never>
}

@MainActor
struct TerminalSessionApplicationEffects {
    let authorizeServer: (Server) async -> Bool
    let refreshLiveActivity: ([ConnectionState]) -> Void
    let recordSuccessfulConnection: (UUID, String) -> Void
    let noteTerminalSessionEnded: (Bool) -> Void
    let recordSplitPaneCreated: () -> Void
}

@MainActor
struct TerminalTmuxConfiguration {
    struct ServerSettings {
        let enabledOverride: Bool?
        let startupBehaviorOverride: TmuxStartupBehavior?
    }

    let deviceID: String
    let enabledByDefault: () -> Bool
    let startupBehaviorByDefault: () -> TmuxStartupBehavior
    let serverSettings: (UUID) -> ServerSettings?
    let themeStyle: @MainActor () -> RemoteTmuxThemeStyle
}

@MainActor
struct TerminalTabManagerDependencies {
    let sshClientFactory: SSHClientFactory
    let networkReadiness: TerminalNetworkReadinessSource
    let applicationIsActive: @MainActor @Sendable () -> Bool
    let appLock: TerminalAppLockSource
    let effects: TerminalSessionApplicationEffects
    let remoteMosh: any TerminalRemoteMoshServicing
    let eternalTerminalRuntime: EternalTerminalRuntimeDependencies
}

#if DEBUG
extension TerminalTabManagerDependencies {
    static func testing(
        networkReadinessPublisher: AnyPublisher<TerminalNetworkReadiness, Never>?,
        liveActivityRefresh: @escaping ([ConnectionState]) -> Void
    ) -> Self {
        let updates = networkReadinessPublisher
            ?? Empty<TerminalNetworkReadiness, Never>().eraseToAnyPublisher()
        return Self(
            sshClientFactory: .testing(),
            networkReadiness: TerminalNetworkReadinessSource(
                initial: .ready,
                updates: updates
            ),
            applicationIsActive: { true },
            appLock: TerminalAppLockSource(
                initialIsLocked: false,
                updates: Empty<Bool, Never>().eraseToAnyPublisher()
            ),
            effects: TerminalSessionApplicationEffects(
                authorizeServer: { _ in true },
                refreshLiveActivity: liveActivityRefresh,
                recordSuccessfulConnection: { _, _ in },
                noteTerminalSessionEnded: { _ in },
                recordSplitPaneCreated: {}
            ),
            remoteMosh: UnavailableTerminalRemoteMoshService(),
            eternalTerminalRuntime: .testing
        )
    }
}

private actor UnavailableTerminalRemoteMoshService: TerminalRemoteMoshServicing {
    func installMoshServer(using client: SSHClient) async throws {
        throw SSHError.notConnected
    }
}
#endif
