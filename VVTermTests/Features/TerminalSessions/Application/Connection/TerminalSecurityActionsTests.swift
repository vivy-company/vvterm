import Foundation
import Testing
@testable import VVTerm

private nonisolated final class TerminalSecurityKeychainBacking: KeychainStoreBacking, @unchecked Sendable {
    private struct Item: Hashable {
        let service: String
        let key: String
        let scope: KeychainStorageScope
    }

    private let lock = NSLock()
    private var values: [Item: Data] = [:]

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
        values.removeValue(forKey: Item(service: service, key: key, scope: scope))
        lock.unlock()
    }

    func keys(service: String, scope: KeychainStorageScope) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.compactMap { item in
            item.service == service && item.scope == scope ? item.key : nil
        }
    }

}

@MainActor
struct TerminalSecurityActionsTests {
    @Test
    func credentialLoadsAutomaticallyBindOnlyTheirInjectedKeychainOwner() throws {
        let server = makeServer()
        var changedServer = server
        changedServer.host = "changed.example.com"
        let firstKeychain = makeKeychainManager()
        let secondKeychain = makeKeychainManager()
        try firstKeychain.storeCredentials(
            ServerCredentials(serverId: server.id, password: "first"),
            for: server
        )
        try secondKeychain.storeCredentials(
            ServerCredentials(serverId: server.id, password: "second"),
            for: server
        )
        let firstActions = AppComposition.makeTerminalSecurityActions(
            keychainManager: firstKeychain,
            knownHostsManager: makeKnownHostsManager()
        )
        let secondActions = AppComposition.makeTerminalSecurityActions(
            keychainManager: secondKeychain,
            knownHostsManager: makeKnownHostsManager()
        )
        #expect(try firstActions.loadCredentials(changedServer).password == "first")
        #expect(try secondActions.loadCredentials(changedServer).password == "second")
    }

    @Test
    func hostKeyActionsRouteApprovalAndRejectionToTheirInjectedOwner() throws {
        let server = makeServer()
        let firstKnownHosts = makeKnownHostsManager()
        let secondKnownHosts = makeKnownHostsManager()
        let firstActions = AppComposition.makeTerminalSecurityActions(
            keychainManager: makeKeychainManager(),
            knownHostsManager: firstKnownHosts
        )
        let secondActions = AppComposition.makeTerminalSecurityActions(
            keychainManager: makeKeychainManager(),
            knownHostsManager: secondKnownHosts
        )
        _ = firstKnownHosts.evaluate(
            host: server.host,
            port: server.port,
            fingerprint: "first-fingerprint",
            keyType: 1,
            keyTypeName: "first-key"
        )
        _ = secondKnownHosts.evaluate(
            host: server.host,
            port: server.port,
            fingerprint: "second-fingerprint",
            keyType: 2,
            keyTypeName: "second-key"
        )
        let firstRequest = try #require(firstActions.pendingHostKeyApproval(server))
        let secondRequest = try #require(secondActions.pendingHostKeyApproval(server))

        #expect(firstRequest.id != secondRequest.id)
        #expect(secondActions.approve(firstRequest, server) == .failed(.expired))
        #expect(firstActions.approve(firstRequest, server) == .approved)
        #expect(firstActions.pendingHostKeyApproval(server) == nil)
        #expect(secondActions.pendingHostKeyApproval(server) == secondRequest)

        firstActions.reject(secondRequest)
        #expect(secondActions.pendingHostKeyApproval(server) == secondRequest)
        secondActions.reject(secondRequest)
        #expect(secondActions.pendingHostKeyApproval(server) == nil)
    }

    private func makeKeychainManager(
        backing: TerminalSecurityKeychainBacking = TerminalSecurityKeychainBacking()
    ) -> KeychainManager {
        return KeychainManager(
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

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 22,
            username: "root",
            authMethod: .password
        )
    }
}
