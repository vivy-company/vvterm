import Foundation
import Testing
@testable import VVTerm

private nonisolated final class StatsCompositionKeychainBacking:
    KeychainStoreBacking,
    @unchecked Sendable {
    enum Failure: Error {
        case readRejected
    }

    private struct Item: Hashable {
        let service: String
        let key: String
        let scope: KeychainStorageScope
    }

    private let lock = NSLock()
    private var values: [Item: Data] = [:]
    private var rejectsReads = false

    func set(
        _ data: Data,
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        values[Item(service: service, key: key, scope: scope)] = data
    }

    func get(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !rejectsReads else { throw Failure.readRejected }
        return values[Item(service: service, key: key, scope: scope)]
    }

    func contains(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws -> Bool {
        try get(service: service, key: key, scope: scope) != nil
    }

    func delete(
        service: String,
        key: String,
        scope: KeychainStorageScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: Item(service: service, key: key, scope: scope))
    }

    func keys(service: String, scope: KeychainStorageScope) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.compactMap { item in
            item.service == service && item.scope == scope ? item.key : nil
        }
    }

    func rejectReads() {
        lock.lock()
        rejectsReads = true
        lock.unlock()
    }

}

@MainActor
struct VVTermAppStatsCompositionTests {
    @Test
    func collectorFactoriesKeepKeychainOwnersIsolated() async throws {
        let server = makeServer()
        var changedServer = server
        changedServer.host = "changed.example.test"
        let firstBacking = StatsCompositionKeychainBacking()
        let secondBacking = StatsCompositionKeychainBacking()
        let firstKeychain = makeKeychainManager(backing: firstBacking)
        let secondKeychain = makeKeychainManager(backing: secondBacking)
        let firstKnownHosts = makeKnownHostsManager()
        let secondKnownHosts = makeKnownHostsManager()
        let firstSSHClientFactory = SSHClientFactory.testing(
            hostKeyVerifier: firstKnownHosts
        )
        let secondSSHClientFactory = SSHClientFactory.testing(
            hostKeyVerifier: secondKnownHosts
        )
        try firstKeychain.storeCredentials(
            ServerCredentials(serverId: server.id, password: "first"),
            for: server
        )
        secondBacking.rejectReads()
        let firstFactory = AppComposition.makeStatsCollectorFactory(
            keychainManager: firstKeychain,
            knownHostsManager: firstKnownHosts,
            connectionOperations: SSHConnectionOperationService(
                clientFactory: firstSSHClientFactory
            ),
            sshClientFactory: firstSSHClientFactory
        )
        let secondFactory = AppComposition.makeStatsCollectorFactory(
            keychainManager: secondKeychain,
            knownHostsManager: secondKnownHosts,
            connectionOperations: SSHConnectionOperationService(
                clientFactory: secondSSHClientFactory
            ),
            sshClientFactory: secondSSHClientFactory
        )
        let firstCollector = firstFactory()
        let secondCollector = secondFactory()

        await firstCollector.startCollecting(for: changedServer)
        await secondCollector.startCollecting(for: changedServer)

        #expect(firstCollector.securityApproval == nil)
        #expect(try firstKeychain.getCredentials(for: changedServer).password == "first")
        guard case .failed = secondCollector.collectionState.phase else {
            Issue.record("The second collector must use its rejecting keychain owner")
            return
        }
    }

    @Test
    func hostApprovalAndRejectionUseOnlyTheirInjectedOwner() async {
        let server = makeServer()
        let firstKnownHosts = makeKnownHostsManager()
        let secondKnownHosts = makeKnownHostsManager()
        let firstChallenge = requireChallenge(
            from: firstKnownHosts.evaluate(
                host: server.host,
                port: server.port,
                fingerprint: "SHA256:first",
                keyType: 1,
                keyTypeName: "ssh-ed25519"
            )
        )
        let secondChallenge = requireChallenge(
            from: secondKnownHosts.evaluate(
                host: server.host,
                port: server.port,
                fingerprint: "SHA256:second",
                keyType: 1,
                keyTypeName: "ssh-ed25519"
            )
        )
        let actions = makeActions(knownHosts: firstKnownHosts)

        let outcome = await actions.approve(.hostKey(firstChallenge))
        actions.reject(.hostKey(secondChallenge))

        #expect(outcome == .approved)
        #expect(firstKnownHosts.pendingChallenge(for: server.host, port: server.port) == nil)
        #expect(
            secondKnownHosts.pendingChallenge(for: server.host, port: server.port)
                == secondChallenge
        )
    }

    @Test
    func staleHostRequestsAreExpired() async {
        let server = makeServer()
        let knownHosts = makeKnownHostsManager()
        let challenge = requireChallenge(
            from: knownHosts.evaluate(
                host: server.host,
                port: server.port,
                fingerprint: "SHA256:stale",
                keyType: 1,
                keyTypeName: "ssh-ed25519"
            )
        )
        knownHosts.reject(challenge)
        let actions = makeActions(knownHosts: knownHosts)

        let hostOutcome = await actions.approve(.hostKey(challenge))

        #expect(hostOutcome == .failed(.expired))
    }

    private func makeActions(
        knownHosts: KnownHostsManager? = nil
    ) -> ServerStatsSecurityApprovalActions {
        AppComposition.makeStatsSecurityApprovalActions(
            knownHostsManager: knownHosts ?? makeKnownHostsManager()
        )
    }

    private func makeKeychainManager(
        backing: StatsCompositionKeychainBacking = StatsCompositionKeychainBacking()
    ) -> KeychainManager {
        KeychainManager(
            store: KeychainStore(
                service: KeychainManager.credentialService,
                backing: backing
            ),
            cloudflareTokenStore: KeychainStore(
                service: KeychainManager.cloudflareTokenService,
                backing: backing
            ),
            isSyncEnabled: { false }
        )
    }

    private func makeKnownHostsManager() -> KnownHostsManager {
        KnownHostsManager(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
    }

    private func requireChallenge(
        from result: KnownHostsManager.VerificationResult
    ) -> KnownHostsManager.Challenge {
        guard case .approvalRequired(let challenge) = result else {
            fatalError("Expected a host-key approval challenge")
        }
        return challenge
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Stats composition",
            host: "stats.example.test",
            username: "tester"
        )
    }
}
