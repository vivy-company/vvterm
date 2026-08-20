import Foundation

nonisolated enum MoshRestoreStartup {
    static func run<Session: Sendable>(
        restore: @escaping @Sendable () async throws -> Session,
        start: @escaping @Sendable (Session) async throws -> Void,
        resize: @escaping @Sendable (Session) async throws -> Void,
        isCurrent: @escaping @Sendable () async -> Bool,
        stop: @escaping @Sendable (Session) async -> Void
    ) async throws -> Session {
        let session = try await restore()
        do {
            try await requireCurrent(isCurrent)
            try await start(session)
            try await requireCurrent(isCurrent)
            try await resize(session)
            try await requireCurrent(isCurrent)
            return session
        } catch {
            await stop(session)
            throw error
        }
    }

    private static func requireCurrent(
        _ isCurrent: @escaping @Sendable () async -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
    }
}
