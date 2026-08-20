import Foundation

@MainActor
protocol TerminalMoshRecoveryServicing: Sendable {
    func hasCheckpoint(for paneId: UUID) -> Bool
    func restoreShell(
        for paneId: UUID,
        using client: SSHClient,
        cols: Int,
        rows: Int
    ) async -> ShellHandle?
    func persistCheckpoint(
        for paneId: UUID,
        using client: SSHClient,
        shellId: UUID,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async
    func prepareForApplicationBackground(
        for paneId: UUID,
        using client: SSHClient,
        shellId: UUID,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async
    func resumeFromApplicationBackground(
        for paneId: UUID,
        using client: SSHClient,
        shellId: UUID,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async
    func deleteCheckpoint(for paneId: UUID) throws
}

#if DEBUG
@MainActor
struct UnavailableTerminalMoshRecoveryService: TerminalMoshRecoveryServicing {
    func hasCheckpoint(for paneId: UUID) -> Bool { false }

    func restoreShell(
        for paneId: UUID,
        using client: SSHClient,
        cols: Int,
        rows: Int
    ) async -> ShellHandle? {
        nil
    }

    func persistCheckpoint(
        for paneId: UUID,
        using client: SSHClient,
        shellId: UUID,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async {}

    func prepareForApplicationBackground(
        for paneId: UUID,
        using client: SSHClient,
        shellId: UUID,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async {}

    func resumeFromApplicationBackground(
        for paneId: UUID,
        using client: SSHClient,
        shellId: UUID,
        isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
    ) async {}

    func deleteCheckpoint(for paneId: UUID) throws {}
}
#endif
