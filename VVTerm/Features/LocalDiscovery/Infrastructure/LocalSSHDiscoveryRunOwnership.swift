import Foundation

nonisolated struct LocalSSHDiscoveryRunOwnership: Equatable, Sendable {
    private(set) var activeRunID: UUID?

    mutating func start(runID: UUID) {
        activeRunID = runID
    }

    func owns(runID: UUID) -> Bool {
        activeRunID == runID
    }

    @discardableResult
    mutating func stop(runID: UUID) -> Bool {
        guard owns(runID: runID) else { return false }
        activeRunID = nil
        return true
    }
}
