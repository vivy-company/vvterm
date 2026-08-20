import Combine
import Foundation

nonisolated struct KnownHostSettingsItem: Identifiable, Equatable, Sendable {
    let host: String
    let port: Int
    let lastSeenAt: Date

    var endpoint: String { "\(host):\(port)" }
    var id: String { endpoint }
}

@MainActor
protocol KnownHostSettingsRepository: AnyObject {
    func loadKnownHosts() -> [KnownHostSettingsItem]
    func removeKnownHost(host: String, port: Int)
    func removeAllKnownHosts()
}

@MainActor
final class KnownHostSettingsCoordinator: ObservableObject {
    @Published private(set) var knownHosts: [KnownHostSettingsItem] = []

    private let repository: any KnownHostSettingsRepository

    init(repository: any KnownHostSettingsRepository) {
        self.repository = repository
    }

    func loadHosts() {
        knownHosts = repository.loadKnownHosts()
    }

    func removeKnownHost(_ knownHost: KnownHostSettingsItem) {
        repository.removeKnownHost(host: knownHost.host, port: knownHost.port)
        loadHosts()
    }

    func removeAllKnownHosts() {
        repository.removeAllKnownHosts()
        loadHosts()
    }
}
