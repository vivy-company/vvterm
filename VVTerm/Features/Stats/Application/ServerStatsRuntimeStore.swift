import Foundation

/// Retains each server's Stats runtime outside the conditional SwiftUI screen.
///
/// This store is intentionally not observable. Only the mounted Stats screen
/// observes its collector, so polling cannot invalidate terminal or toolbar UI.
@MainActor
final class ServerStatsRuntimeStore {
    private let makeCollector: @MainActor () -> ServerStatsCollector
    private var collectorsByServerID: [UUID: ServerStatsCollector] = [:]

    init(makeCollector: @escaping @MainActor () -> ServerStatsCollector) {
        self.makeCollector = makeCollector
    }

    func collector(for serverID: UUID) -> ServerStatsCollector {
        if let collector = collectorsByServerID[serverID] {
            return collector
        }

        let collector = makeCollector()
        collectorsByServerID[serverID] = collector
        return collector
    }

    func releaseCollector(for serverID: UUID) {
        collectorsByServerID.removeValue(forKey: serverID)?.stopCollecting()
    }
}
