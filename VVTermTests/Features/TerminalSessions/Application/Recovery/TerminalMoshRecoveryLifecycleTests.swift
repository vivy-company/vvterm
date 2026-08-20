import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class TerminalMoshLifecycleSnapshotStore: TerminalTabSnapshotStoring {
    private var data: Data?

    func loadSnapshotData() -> Data? { data }
    func saveSnapshotData(_ data: Data) { self.data = data }
    func removeSnapshotData() { data = nil }
}

private final class TerminalMoshLifecycleETStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

@MainActor
private final class RecordingTerminalMoshRecoveryService: TerminalMoshRecoveryServicing {
    private(set) var deletedPaneIds: [UUID] = []

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

    func deleteCheckpoint(for paneId: UUID) throws {
        deletedPaneIds.append(paneId)
    }
}

@MainActor
struct TerminalMoshRecoveryLifecycleTests {
    @Test
    func explicitCloseDeletesCheckpointAndTerminationPreservesIt() async {
        let recovery = RecordingTerminalMoshRecoveryService()
        let manager = TerminalTabManager(
            snapshotStore: TerminalMoshLifecycleSnapshotStore(),
            networkReadinessPublisher: nil,
            liveActivityRefresh: { _ in },
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            eternalTerminalResumeStore: TerminalMoshLifecycleETStore(),
            moshRecovery: recovery
        )
        let serverId = UUID()
        let closedTab = TerminalTab(serverId: serverId, title: "Close")
        install(closedTab, in: manager)

        manager.closeTab(closedTab)

        #expect(recovery.deletedPaneIds == [closedTab.rootPaneId])

        let preservedTab = TerminalTab(serverId: serverId, title: "Terminate")
        install(preservedTab, in: manager)

        await manager.beginApplicationTermination().value

        #expect(recovery.deletedPaneIds == [closedTab.rootPaneId])
        #expect(manager.sessionState.tabs(for: serverId).map(\.id) == [preservedTab.id])
    }

    private func install(_ tab: TerminalTab, in manager: TerminalTabManager) {
        manager.sessionState.install(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ), select: true)
    }
}
