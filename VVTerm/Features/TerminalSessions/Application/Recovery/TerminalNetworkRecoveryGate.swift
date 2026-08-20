import Foundation

nonisolated struct TerminalNetworkRecoveryGate {
    enum Action: Equatable, Sendable {
        case none
        case wait(UUID)
        case resume(UUID)
    }

    private var generation: UUID?

    mutating func receive(
        _ readiness: TerminalNetworkReadiness,
        shouldWait: Bool
    ) -> Action {
        switch readiness {
        case .unknown:
            return .none

        case .unavailable:
            guard shouldWait else { return .none }
            let activeGeneration = generation ?? UUID()
            generation = activeGeneration
            return .wait(activeGeneration)

        case .ready:
            guard let generation else { return .none }
            self.generation = nil
            return .resume(generation)
        }
    }
}
