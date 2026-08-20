import Combine
import ETSession
import Foundation
@testable import VVTerm

@MainActor
enum TerminalTestComposition {
    static func makeManager() -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: SnapshotStore(),
            networkReadinessPublisher: Empty<TerminalNetworkReadiness, Never>()
                .eraseToAnyPublisher(),
            liveActivityRefresh: { _ in },
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            eternalTerminalResumeStore: ResumeStore(),
            moshRecovery: UnavailableTerminalMoshRecoveryService()
        )
    }

    private final class SnapshotStore: TerminalTabSnapshotStoring {
        private var data: Data?

        func loadSnapshotData() -> Data? { data }
        func saveSnapshotData(_ data: Data) { self.data = data }
        func removeSnapshotData() { data = nil }
    }

    private final class ResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
        func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
        func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
        func hasCheckpoint(for paneId: UUID) -> Bool { false }
        func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
        func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
        func deleteResumeState(for paneId: UUID) throws {}
    }
}
