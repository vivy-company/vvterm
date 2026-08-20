import Foundation

@MainActor
final class StatsPreferencesResolutionChannel:
    StatsPreferencesResolutionSource,
    StatsPreferencesResolutionPublishing {
    typealias Observer = (StatsPreferences) -> Void

    private var observers: [UUID: Observer] = [:]

    @discardableResult
    func observeStatsPreferences(
        _ observer: @escaping Observer
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeStatsPreferencesObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func publishStatsPreferences(_ preferences: StatsPreferences) {
        for observer in Array(observers.values) {
            observer(preferences)
        }
    }
}
