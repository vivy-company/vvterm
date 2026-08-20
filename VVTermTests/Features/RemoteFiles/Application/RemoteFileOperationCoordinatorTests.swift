import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileOperationCoordinatorTests {
    @Test
    func newerPreparedFileRequestRejectsStaleCompletion() {
        let coordinator = makeCoordinator()
        let staleID = UUID()
        let currentID = UUID()
        var cleanedIDs: [UUID] = []
        var presentedIDs: [UUID] = []

        coordinator.beginPreparedFileRequest(staleID, purpose: .share)
        coordinator.beginPreparedFileRequest(currentID, purpose: .share)
        coordinator.publishPreparedFile(
            .init(id: staleID, purpose: .share, url: URL(fileURLWithPath: "/tmp/stale"), filename: "stale"),
            cleanup: { cleanedIDs.append(staleID) },
            onPrepared: { presentedIDs.append($0.id) }
        )
        coordinator.publishPreparedFile(
            .init(id: currentID, purpose: .share, url: URL(fileURLWithPath: "/tmp/current"), filename: "current"),
            cleanup: { cleanedIDs.append(currentID) },
            onPrepared: { presentedIDs.append($0.id) }
        )

        #expect(cleanedIDs == [staleID])
        #expect(presentedIDs == [currentID])

        coordinator.releasePreparedFile(currentID)
        #expect(cleanedIDs == [staleID, currentID])
    }

    @Test
    func cancelAllReleasesPreparedFilesExactlyOnce() {
        let coordinator = makeCoordinator()
        let id = UUID()
        var cleanupCount = 0
        coordinator.beginPreparedFileRequest(id, purpose: .downloadExport)
        coordinator.publishPreparedFile(
            .init(id: id, purpose: .downloadExport, url: URL(fileURLWithPath: "/tmp/export"), filename: "export"),
            cleanup: { cleanupCount += 1 },
            onPrepared: { _ in }
        )

        coordinator.cancelAll()
        coordinator.releasePreparedFile(id)

        #expect(cleanupCount == 1)
    }

    private func makeCoordinator() -> RemoteFileOperationCoordinator {
        RemoteFileOperationCoordinator(
            server: Server(
                workspaceId: UUID(),
                name: "Production",
                host: "example.com",
                username: "root"
            ),
            securityApprovalActions: .unavailable
        )
    }
}
