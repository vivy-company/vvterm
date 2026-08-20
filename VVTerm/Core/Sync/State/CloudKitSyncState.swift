import Foundation

nonisolated struct CloudKitSyncState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case error(String)
        case offline
        case disabled
    }

    enum OperationCompletion: Equatable, Sendable {
        case success
        case failure(String)
    }

    private struct AvailableContext: Equatable, Sendable {
        var activeOperations: Set<UUID> = []
        var latestOperationID: UUID?
        var latestFailure: String?
    }

    private enum Phase: Equatable, Sendable {
        case checkingAccount
        case available(AvailableContext)
        case accountFailure(String)
        case offline
        case disabled
    }

    private var phase: Phase = .checkingAccount

    static var available: Self {
        Self(phase: .available(AvailableContext()))
    }

    var status: Status {
        switch phase {
        case .checkingAccount:
            return .idle
        case .available(let context):
            if !context.activeOperations.isEmpty {
                return .syncing
            }
            if let latestFailure = context.latestFailure {
                return .error(latestFailure)
            }
            return .idle
        case .accountFailure(let message):
            return .error(message)
        case .offline:
            return .offline
        case .disabled:
            return .disabled
        }
    }

    var isAvailable: Bool {
        if case .available = phase {
            return true
        }
        return false
    }

    mutating func markAvailable() {
        guard !isAvailable else { return }
        phase = .available(AvailableContext())
    }

    mutating func markCheckingAccount() {
        phase = .checkingAccount
    }

    mutating func markAccountFailure(_ message: String) {
        phase = .accountFailure(message)
    }

    mutating func markOffline() {
        phase = .offline
    }

    mutating func markDisabled() {
        phase = .disabled
    }

    @discardableResult
    mutating func beginOperation(_ id: UUID) -> Bool {
        guard case .available(var context) = phase else { return false }
        context.activeOperations.insert(id)
        context.latestOperationID = id
        context.latestFailure = nil
        phase = .available(context)
        return true
    }

    mutating func completeOperation(_ id: UUID, with completion: OperationCompletion) {
        guard case .available(var context) = phase,
              context.activeOperations.remove(id) != nil else {
            return
        }

        if context.latestOperationID == id {
            switch completion {
            case .success:
                context.latestFailure = nil
            case .failure(let message):
                context.latestFailure = message
            }
        }

        phase = .available(context)
    }
}
