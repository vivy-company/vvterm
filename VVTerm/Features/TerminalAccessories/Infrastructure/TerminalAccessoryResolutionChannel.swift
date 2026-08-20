import Foundation

@MainActor
final class TerminalAccessoryResolutionChannel:
    TerminalAccessoryResolutionSource,
    TerminalAccessoryResolutionPublishing {
    typealias Observer = (TerminalAccessoryProfile) -> Void

    private var observers: [UUID: Observer] = [:]

    @discardableResult
    func observeTerminalAccessoryProfile(
        _ observer: @escaping Observer
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeTerminalAccessoryProfileObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func publishTerminalAccessoryProfile(_ profile: TerminalAccessoryProfile) {
        for observer in Array(observers.values) {
            observer(profile)
        }
    }
}
