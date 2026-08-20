import Foundation
import Testing
@testable import VVTerm

struct RemoteFileDropPolicyTests {
    @Test
    func sameServerDropPlansMovesAndRemovesDuplicatePaths() throws {
        let serverID = UUID()
        let first = makeEntry(name: "one.txt", path: "/source/one.txt")
        let second = makeEntry(name: "two.txt", path: "/source/two.txt")

        let plan = try RemoteFileDropPolicy.plan(
            payloads: [
                RemoteFileDragPayload(serverId: serverID, entries: [first, second]),
                RemoteFileDragPayload(serverId: serverID, entry: first)
            ],
            destinationServerID: serverID,
            destinationDirectoryPath: "/destination/"
        )

        #expect(plan == .move([
            .init(entry: first, destinationPath: "/destination/one.txt"),
            .init(entry: second, destinationPath: "/destination/two.txt")
        ]))
    }

    @Test
    func crossServerDropPlansOneCopy() throws {
        let sourceServerID = UUID()
        let destinationServerID = UUID()
        let entry = makeEntry(name: "one.txt", path: "/source/one.txt")

        let plan = try RemoteFileDropPolicy.plan(
            payloads: [RemoteFileDragPayload(serverId: sourceServerID, entry: entry)],
            destinationServerID: destinationServerID,
            destinationDirectoryPath: "/destination/../archive"
        )

        #expect(plan == .copy(
            sourceServerID: sourceServerID,
            entries: [entry],
            destinationDirectory: "/archive"
        ))
    }

    @Test
    func dropRejectsItemsFromMultipleServers() {
        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFileDropPolicy.plan(
                payloads: [
                    RemoteFileDragPayload(
                        serverId: UUID(),
                        entry: makeEntry(name: "one.txt", path: "/one.txt")
                    ),
                    RemoteFileDragPayload(
                        serverId: UUID(),
                        entry: makeEntry(name: "two.txt", path: "/two.txt")
                    )
                ],
                destinationServerID: UUID(),
                destinationDirectoryPath: "/destination"
            )
        }
    }

    @Test
    func dropRejectsMovingFolderIntoDescendant() {
        let serverID = UUID()
        let folder = makeEntry(name: "folder", path: "/source/folder", type: .directory)

        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFileDropPolicy.plan(
                payloads: [RemoteFileDragPayload(serverId: serverID, entry: folder)],
                destinationServerID: serverID,
                destinationDirectoryPath: "/source/folder/child"
            )
        }
    }

    private func makeEntry(
        name: String,
        path: String,
        type: RemoteFileType = .file
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}
