@MainActor
private final class AppKnownHostSettingsRepository: KnownHostSettingsRepository {
    private let knownHosts: KnownHostsManager

    init(knownHosts: KnownHostsManager) {
        self.knownHosts = knownHosts
    }

    func loadKnownHosts() -> [KnownHostSettingsItem] {
        knownHosts.entries().map { entry in
            KnownHostSettingsItem(
                host: entry.host,
                port: entry.port,
                lastSeenAt: entry.lastSeenAt
            )
        }
    }

    func removeKnownHost(host: String, port: Int) {
        knownHosts.remove(host: host, port: port)
    }

    func removeAllKnownHosts() {
        knownHosts.removeAll()
    }
}

@MainActor
enum KnownHostSettingsLiveComposition {
    static func makeCoordinator(
        knownHosts: KnownHostsManager
    ) -> KnownHostSettingsCoordinator {
        KnownHostSettingsCoordinator(
            repository: AppKnownHostSettingsRepository(knownHosts: knownHosts)
        )
    }
}
