import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class KnownHostSettingsRepositorySpy: KnownHostSettingsRepository {
    var storedHosts: [KnownHostSettingsItem] = []
    var loadCount = 0
    var removedHost: (host: String, port: Int)?
    var removeAllCount = 0

    func loadKnownHosts() -> [KnownHostSettingsItem] {
        loadCount += 1
        return storedHosts
    }

    func removeKnownHost(host: String, port: Int) {
        removedHost = (host, port)
        storedHosts.removeAll { $0.host == host && $0.port == port }
    }

    func removeAllKnownHosts() {
        removeAllCount += 1
        storedHosts = []
    }
}

@MainActor
struct KnownHostSettingsCoordinatorTests {
    @Test
    func loadPublishesKnownHostsAndDerivesCount() {
        let repository = KnownHostSettingsRepositorySpy()
        repository.storedHosts = [
            knownHost(host: "first.example.com", port: 22),
            knownHost(host: "second.example.com", port: 2222),
        ]
        let coordinator = KnownHostSettingsCoordinator(repository: repository)

        coordinator.loadHosts()

        #expect(coordinator.knownHosts == repository.storedHosts)
        #expect(coordinator.knownHosts.count == 2)
        #expect(repository.loadCount == 1)
    }

    @Test
    func successfulSingleRemovalReloadsHosts() {
        let repository = KnownHostSettingsRepositorySpy()
        let first = knownHost(host: "first.example.com", port: 22)
        let second = knownHost(host: "second.example.com", port: 2222)
        repository.storedHosts = [first, second]
        let coordinator = KnownHostSettingsCoordinator(repository: repository)
        coordinator.loadHosts()

        coordinator.removeKnownHost(first)

        #expect(repository.removedHost?.host == first.host)
        #expect(repository.removedHost?.port == first.port)
        #expect(coordinator.knownHosts == [second])
        #expect(repository.loadCount == 2)
    }

    @Test
    func successfulAllRemovalReloadsHosts() {
        let repository = KnownHostSettingsRepositorySpy()
        repository.storedHosts = [knownHost(host: "example.com", port: 22)]
        let coordinator = KnownHostSettingsCoordinator(repository: repository)
        coordinator.loadHosts()

        coordinator.removeAllKnownHosts()

        #expect(coordinator.knownHosts.isEmpty)
        #expect(repository.removeAllCount == 1)
        #expect(repository.loadCount == 2)
    }

    private func knownHost(host: String, port: Int) -> KnownHostSettingsItem {
        KnownHostSettingsItem(
            host: host,
            port: port,
            lastSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
