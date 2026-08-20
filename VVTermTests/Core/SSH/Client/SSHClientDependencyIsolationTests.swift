import Foundation
import MoshBootstrap
import Testing
@testable import VVTerm

private actor SSHMoshBootstrapSpy: SSHMoshBootstrapping {
    private let connectInfo: MoshServerConnectInfo
    private(set) var bootstrapCount = 0
    private(set) var terminatedPIDs: [Int32] = []

    init(port: UInt16, serverPID: Int32) {
        connectInfo = MoshServerConnectInfo(
            port: port,
            key: "test-key-\(port)",
            serverPID: serverPID,
            rawOutput: "MOSH CONNECT \(port) test-key-\(port)"
        )
    }

    func bootstrapConnectInfo(
        terminalType: RemoteTerminalType,
        startCommand: String?,
        portRange: ClosedRange<Int>,
        execute: @escaping SSHMoshCommandExecutor
    ) async throws -> MoshServerConnectInfo {
        bootstrapCount += 1
        return connectInfo
    }

    func terminateMoshServer(
        pid: Int32,
        execute: @escaping SSHMoshCommandExecutor
    ) async {
        terminatedPIDs.append(pid)
    }
}

@MainActor
struct SSHClientDependencyIsolationTests {
    @Test
    func twoFactoriesKeepHostApprovalMoshAndRuntimeSettingsIsolated() async throws {
        let (firstDefaults, firstSuiteName) = makeDefaults()
        let (secondDefaults, secondSuiteName) = makeDefaults()
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuiteName)
            secondDefaults.removePersistentDomain(forName: secondSuiteName)
        }
        let firstKnownHosts = KnownHostsManager(
            defaults: firstDefaults,
            storageKey: "first-known-hosts"
        )
        let secondKnownHosts = KnownHostsManager(
            defaults: secondDefaults,
            storageKey: "second-known-hosts"
        )
        let firstMosh = SSHMoshBootstrapSpy(port: 60_101, serverPID: 101)
        let secondMosh = SSHMoshBootstrapSpy(port: 60_202, serverPID: 202)
        let first = SSHClientFactory(
            runtimeSettings: {
                SSHRuntimeSettings(keepAliveEnabled: false, keepAliveIntervalSeconds: 10)
            },
            hostKeyVerifier: firstKnownHosts,
            moshBootstrap: firstMosh
        ).makeClient()
        let second = SSHClientFactory(
            runtimeSettings: {
                SSHRuntimeSettings(keepAliveEnabled: true, keepAliveIntervalSeconds: 77)
            },
            hostKeyVerifier: secondKnownHosts,
            moshBootstrap: secondMosh
        ).makeClient()
        let candidate = SSHHostKeyCandidate(
            host: "owner.example.test",
            port: 22,
            fingerprint: "SHA256:owner",
            keyType: 1,
            keyTypeName: "ssh-ed25519"
        )

        #expect(await first.runtimeSettingsForTesting().keepAlive == .disabled)
        #expect(
            await second.runtimeSettingsForTesting().keepAlive
                == .enabled(intervalSeconds: 77)
        )
        #expect(await first.hostKeyDecisionForTesting(candidate) == .approvalRequired)
        #expect(await second.hostKeyDecisionForTesting(candidate) == .approvalRequired)

        let firstChallenge = try #require(firstKnownHosts.pendingChallenge(
            for: candidate.host,
            port: candidate.port
        ))
        #expect(firstKnownHosts.approve(firstChallenge))
        #expect(await first.hostKeyDecisionForTesting(candidate) == .trusted)
        #expect(await second.hostKeyDecisionForTesting(candidate) == .approvalRequired)

        let firstConnectInfo = try await first.bootstrapMoshForTesting { _, _ in "" }
        await first.terminateMoshForTesting(pid: 101) { _, _ in "" }
        #expect(firstConnectInfo.port == 60_101)
        #expect(await firstMosh.bootstrapCount == 1)
        #expect(await firstMosh.terminatedPIDs == [101])
        #expect(await secondMosh.bootstrapCount == 0)
        #expect(await secondMosh.terminatedPIDs.isEmpty)

        let secondConnectInfo = try await second.bootstrapMoshForTesting { _, _ in "" }
        #expect(secondConnectInfo.port == 60_202)
        #expect(await secondMosh.bootstrapCount == 1)
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "SSHClientDependencyIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }
}
