import Foundation
import Testing
@testable import VVTerm

struct RemoteFileTemporaryStorageTests {
    @Test
    func previewFilesArePlacedInPreviewSubdirectoryAndKeepExtension() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "frame.mov", path: "/tmp/frame.mov")

        let url = try storage.makePreviewFileURL(for: entry)

        #expect(url.pathExtension == "mov")
        #expect(url.path.contains("/Previews/"))
    }

    @Test
    func removePreviewArtifactDeletesStoredFile() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "frame.mov", path: "/tmp/frame.mov")
        let previewURL = try storage.makePreviewFileURL(for: entry)
        try Data([0x01, 0x02]).write(to: previewURL)
        let payload = RemoteFileViewerPayload(
            previewKind: .video,
            entry: entry,
            textPreview: nil,
            previewFileURL: previewURL,
            isTruncated: false,
            unavailableMessage: nil,
            requiresExplicitDownload: false,
            previewByteCount: 2
        )

        storage.removePreviewArtifact(for: payload)

        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
    }

    @Test
    func failedDragExportRemovesOwnedTemporaryRoot() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "folder", path: "/tmp/folder", type: .directory)

        await #expect(throws: TestFailure.self) {
            try await storage.prepareDragExport(for: entry) { itemURL in
                try FileManager.default.createDirectory(
                    at: itemURL,
                    withIntermediateDirectories: false
                )
                try Data("complete child".utf8).write(
                    to: itemURL.appendingPathComponent("first.txt")
                )
                throw TestFailure()
            }
        }

        let dragRoot = rootDirectory.appendingPathComponent("DraggedItems", isDirectory: true)
        let retainedItems = try FileManager.default.contentsOfDirectory(atPath: dragRoot.path)
        #expect(retainedItems.isEmpty)
    }

    @Test
    func cancelledDragExportRemovesOwnedTemporaryRoot() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "large.bin", path: "/tmp/large.bin")

        await #expect(throws: CancellationError.self) {
            try await storage.prepareDragExport(for: entry) { itemURL in
                try Data("partial".utf8).write(to: itemURL)
                throw CancellationError()
            }
        }

        let dragRoot = rootDirectory.appendingPathComponent("DraggedItems", isDirectory: true)
        let retainedItems = try FileManager.default.contentsOfDirectory(atPath: dragRoot.path)
        #expect(retainedItems.isEmpty)
    }

    @Test
    func staleSuccessfulDragExportIsRemovedOnNextExport() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "first.txt", path: "/tmp/first.txt")
        let firstURL = try await storage.prepareDragExport(for: entry) { itemURL in
            try Data("first".utf8).write(to: itemURL)
        }
        let firstRoot = firstURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(25 * 60 * 60))],
            ofItemAtPath: firstRoot.path
        )

        _ = try await storage.prepareDragExport(
            for: makeEntry(name: "second.txt", path: "/tmp/second.txt")
        ) { itemURL in
            try Data("second".utf8).write(to: itemURL)
        }

        #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
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

    private struct TestFailure: Error {}
}
