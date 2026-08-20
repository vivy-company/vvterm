import Foundation

nonisolated struct ServerDataLoadState: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case loading(operationID: UUID)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle

    var isLoading: Bool {
        if case .loading = phase {
            return true
        }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = phase {
            return message
        }
        return nil
    }

    mutating func start(operationID: UUID) -> UUID {
        phase = .loading(operationID: operationID)
        return operationID
    }

    @discardableResult
    mutating func finish(operationID: UUID) -> Bool {
        guard case .loading(operationID) = phase else { return false }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func fail(operationID: UUID, message: String) -> Bool {
        guard case .loading(operationID) = phase else { return false }
        phase = .failed(message: message)
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}

nonisolated struct ServerManagerSnapshot: Equatable, Sendable {
    var servers: [Server]
    var workspaces: [Workspace]
    var loadState: ServerDataLoadState
    var localStorageIssues: [ServerLocalStorageIssue]
    var ambiguousCloudRecovery: AmbiguousCloudRecoveryState?
    var freePlanGeneration: FreePlanGeneration

    init(
        servers: [Server] = [],
        workspaces: [Workspace] = [],
        loadState: ServerDataLoadState = ServerDataLoadState(),
        localStorageIssues: [ServerLocalStorageIssue] = [],
        ambiguousCloudRecovery: AmbiguousCloudRecoveryState? = nil,
        freePlanGeneration: FreePlanGeneration
    ) {
        self.servers = servers
        self.workspaces = workspaces
        self.loadState = loadState
        self.localStorageIssues = localStorageIssues
        self.ambiguousCloudRecovery = ambiguousCloudRecovery
        self.freePlanGeneration = freePlanGeneration
    }
}
