import Foundation
import MoshBootstrap

nonisolated struct SSHHostKeyCandidate: Equatable, Sendable {
    let host: String
    let port: Int
    let fingerprint: String
    let keyType: Int
    let keyTypeName: String
}

nonisolated enum SSHHostKeyVerificationDecision: Equatable, Sendable {
    case trusted
    case approvalRequired
}

nonisolated protocol SSHHostKeyVerifying: Sendable {
    func verify(_ candidate: SSHHostKeyCandidate) -> SSHHostKeyVerificationDecision
}

typealias SSHMoshCommandExecutor = @Sendable (
    _ command: String,
    _ timeout: Duration
) async throws -> String

nonisolated protocol SSHMoshBootstrapping: Sendable {
    func bootstrapConnectInfo(
        terminalType: RemoteTerminalType,
        startCommand: String?,
        portRange: ClosedRange<Int>,
        execute: @escaping SSHMoshCommandExecutor
    ) async throws -> MoshServerConnectInfo

    func terminateMoshServer(
        pid: Int32,
        execute: @escaping SSHMoshCommandExecutor
    ) async
}

nonisolated struct SSHClientFactory: Sendable {
    private let runtimeSettings: @Sendable () -> SSHRuntimeSettings
    private let hostKeyVerifier: any SSHHostKeyVerifying
    private let moshBootstrap: any SSHMoshBootstrapping

    init(
        runtimeSettings: @escaping @Sendable () -> SSHRuntimeSettings,
        hostKeyVerifier: any SSHHostKeyVerifying,
        moshBootstrap: any SSHMoshBootstrapping
    ) {
        self.runtimeSettings = runtimeSettings
        self.hostKeyVerifier = hostKeyVerifier
        self.moshBootstrap = moshBootstrap
    }

    func makeClient(connectTimeout: Duration = .seconds(30)) -> SSHClient {
        SSHClient(
            connectTimeout: connectTimeout,
            runtimeSettings: runtimeSettings(),
            hostKeyVerifier: hostKeyVerifier,
            moshBootstrap: moshBootstrap
        )
    }
}

/// `UserDefaults` supports concurrent reads, and this source never mutates its
/// reference after initialization. Each call creates an immutable settings value.
private nonisolated final class SSHRuntimeSettingsSource: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func current() -> SSHRuntimeSettings {
        SSHRuntimeSettings(defaults: defaults)
    }
}

nonisolated enum SSHClientLiveComposition {
    static func makeFactory(
        defaults: UserDefaults,
        knownHostsManager: KnownHostsManager,
        remoteMoshManager: RemoteMoshManager
    ) -> SSHClientFactory {
        let runtimeSettings = SSHRuntimeSettingsSource(defaults: defaults)
        return SSHClientFactory(
            runtimeSettings: {
                runtimeSettings.current()
            },
            hostKeyVerifier: knownHostsManager,
            moshBootstrap: remoteMoshManager
        )
    }
}

extension KnownHostsManager: SSHHostKeyVerifying {
    nonisolated func verify(
        _ candidate: SSHHostKeyCandidate
    ) -> SSHHostKeyVerificationDecision {
        switch evaluate(
            host: candidate.host,
            port: candidate.port,
            fingerprint: candidate.fingerprint,
            keyType: candidate.keyType,
            keyTypeName: candidate.keyTypeName
        ) {
        case .trusted:
            return .trusted
        case .approvalRequired:
            return .approvalRequired
        }
    }
}

extension RemoteMoshManager: SSHMoshBootstrapping {}

#if DEBUG
extension SSHClientFactory {
    static func testing(
        runtimeSettings: SSHRuntimeSettings = SSHRuntimeSettings(
            keepAliveEnabled: true,
            keepAliveIntervalSeconds: SSHRuntimeSettings.defaultKeepAliveIntervalSeconds
        ),
        hostKeyVerifier: any SSHHostKeyVerifying = TestingSSHHostKeyVerifier(),
        moshBootstrap: any SSHMoshBootstrapping = TestingSSHMoshBootstrap()
    ) -> SSHClientFactory {
        SSHClientFactory(
            runtimeSettings: { runtimeSettings },
            hostKeyVerifier: hostKeyVerifier,
            moshBootstrap: moshBootstrap
        )
    }
}

extension SSHClient {
    static func testing(
        connectTimeout: Duration = .seconds(30),
        runtimeSettings: SSHRuntimeSettings = SSHRuntimeSettings(
            keepAliveEnabled: true,
            keepAliveIntervalSeconds: SSHRuntimeSettings.defaultKeepAliveIntervalSeconds
        ),
        hostKeyVerifier: any SSHHostKeyVerifying = TestingSSHHostKeyVerifier(),
        moshBootstrap: any SSHMoshBootstrapping = TestingSSHMoshBootstrap()
    ) -> SSHClient {
        SSHClient(
            connectTimeout: connectTimeout,
            runtimeSettings: runtimeSettings,
            hostKeyVerifier: hostKeyVerifier,
            moshBootstrap: moshBootstrap
        )
    }
}

nonisolated struct TestingSSHHostKeyVerifier: SSHHostKeyVerifying {
    func verify(_ candidate: SSHHostKeyCandidate) -> SSHHostKeyVerificationDecision {
        .trusted
    }
}

actor TestingSSHMoshBootstrap: SSHMoshBootstrapping {
    func bootstrapConnectInfo(
        terminalType: RemoteTerminalType,
        startCommand: String?,
        portRange: ClosedRange<Int>,
        execute: @escaping SSHMoshCommandExecutor
    ) async throws -> MoshServerConnectInfo {
        throw SSHError.moshBootstrapFailed("Unavailable in this test")
    }

    func terminateMoshServer(
        pid: Int32,
        execute: @escaping SSHMoshCommandExecutor
    ) async {}
}
#endif
