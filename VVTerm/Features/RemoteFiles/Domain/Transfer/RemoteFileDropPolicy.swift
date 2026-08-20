import Foundation

nonisolated enum RemoteFileDropPlan: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        let entry: RemoteFileEntry
        let destinationPath: String
    }

    case move([Move])
    case copy(sourceServerID: UUID, entries: [RemoteFileEntry], destinationDirectory: String)
}

nonisolated enum RemoteFileDropPolicy {
    static func plan(
        payloads: [RemoteFileDragPayload],
        destinationServerID: UUID,
        destinationDirectoryPath: String
    ) throws -> RemoteFileDropPlan {
        let sourceServerIDs = Set(payloads.map(\.serverId))
        guard sourceServerIDs.count == 1, let sourceServerID = sourceServerIDs.first else {
            throw RemoteFileBrowserError.failed(
                String(localized: "A single drop can only contain items from one remote server.")
            )
        }

        var seenPaths = Set<String>()
        let entries = payloads
            .flatMap(\.entries)
            .filter { seenPaths.insert($0.path).inserted }
        guard !entries.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid remote items were dropped."))
        }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        guard sourceServerID == destinationServerID else {
            return .copy(
                sourceServerID: sourceServerID,
                entries: entries,
                destinationDirectory: destinationDirectory
            )
        }

        let moves = try entries.compactMap { entry -> RemoteFileDropPlan.Move? in
            let leaf = try RemoteFileLeaf(validating: entry.name)
            let destinationPath = RemoteFilePath.appending(leaf, to: destinationDirectory)
            guard destinationPath != entry.path else { return nil }

            if entry.type == .directory {
                let sourcePath = RemoteFilePath.normalize(entry.path)
                guard destinationDirectory != sourcePath,
                      !RemoteFilePath.isStrictDescendant(destinationDirectory, of: sourcePath)
                else {
                    throw RemoteFileBrowserError.failed(
                        String(localized: "A folder cannot be moved into itself or one of its descendants.")
                    )
                }
            }

            return RemoteFileDropPlan.Move(entry: entry, destinationPath: destinationPath)
        }
        return .move(moves)
    }
}
