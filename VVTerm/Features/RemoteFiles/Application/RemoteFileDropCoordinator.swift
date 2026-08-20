import Foundation

extension RemoteFileBrowserStore {
    func transferDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        destinationTab: RemoteFileTab,
        destinationServer: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        let plan = try RemoteFileDropPolicy.plan(
            payloads: payloads,
            destinationServerID: destinationServer.id,
            destinationDirectoryPath: destinationDirectoryPath
        )

        switch plan {
        case .move(let moves):
            let totalUnitCount = max(1, moves.count)
            for (index, move) in moves.enumerated() {
                try Task.checkCancellation()
                try await renameItem(
                    at: move.entry.path,
                    to: move.destinationPath,
                    in: destinationTab,
                    server: destinationServer
                )
                onProgress?(
                    TransferProgress(
                        completedUnitCount: index + 1,
                        totalUnitCount: totalUnitCount,
                        currentItemName: move.entry.name
                    )
                )
            }

        case .copy(let sourceServerID, let entries, let destinationDirectory):
            try await copyEntries(
                entries,
                from: sourceServerID,
                to: destinationDirectory,
                destinationTab: destinationTab,
                destinationServer: destinationServer,
                onProgress: onProgress
            )
        }
    }
}
