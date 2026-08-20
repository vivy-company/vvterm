import Foundation

nonisolated final class RemoteFileTemporaryStorage: @unchecked Sendable {
    private struct DragExport {
        let rootURL: URL
        let itemURL: URL
    }

    private let fileManager: FileManager
    private let rootDirectory: URL
    private static let staleDragExportAge: TimeInterval = 24 * 60 * 60
    private static let staleDragExportCleanupLimit = 64

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("VVTermRemoteFiles", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
    }

    func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeFileURL(in: "Previews", suggestedName: entry.name)
    }

    func makeTransferFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeFileURL(in: "Transfers", suggestedName: entry.name.isEmpty ? "download" : entry.name)
    }

    func prepareDragExport(
        for entry: RemoteFileEntry,
        download: @Sendable (URL) async throws -> Void
    ) async throws -> URL {
        let export = try makeDragExport(for: entry)
        do {
            try await download(export.itemURL)
            try Task.checkCancellation()
            return export.itemURL
        } catch {
            removeItem(at: export.rootURL)
            throw error
        }
    }

    func removeItem(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func removePreviewArtifact(for payload: RemoteFileViewerPayload?) {
        guard let previewFileURL = payload?.previewFileURL else { return }
        removeItem(at: previewFileURL)
    }

    func removeStaleDragExports(olderThan cutoff: Date) {
        let dragRoot = dragRootDirectory
        guard let exports = try? fileManager.contentsOfDirectory(
            at: dragRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for exportURL in exports.prefix(Self.staleDragExportCleanupLimit) {
            guard let values = try? exportURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ),
            values.isDirectory == true,
            let modifiedAt = values.contentModificationDate,
            modifiedAt < cutoff else {
                continue
            }
            removeItem(at: exportURL)
        }
    }

    private var dragRootDirectory: URL {
        rootDirectory.appendingPathComponent("DraggedItems", isDirectory: true)
    }

    private func makeDragExport(for entry: RemoteFileEntry) throws -> DragExport {
        let dragRoot = dragRootDirectory
        try fileManager.createDirectory(at: dragRoot, withIntermediateDirectories: true)
        removeStaleDragExports(olderThan: Date().addingTimeInterval(-Self.staleDragExportAge))

        let exportRoot = dragRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: false)

        do {
            let fallbackName = entry.type == .directory ? "Folder" : "download"
            let filename = entry.name.isEmpty ? fallbackName : entry.name
            let itemURL = try RemoteFileLocalPath.descendant(
                named: RemoteFileLeaf(validating: filename),
                in: exportRoot,
                operationRootURL: exportRoot,
                isDirectory: entry.type == .directory
            )
            return DragExport(rootURL: exportRoot, itemURL: itemURL)
        } catch {
            removeItem(at: exportRoot)
            throw error
        }
    }

    private func makeFileURL(in subdirectoryName: String, suggestedName: String) throws -> URL {
        let directory = rootDirectory.appendingPathComponent(subdirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = URL(fileURLWithPath: suggestedName)
        let fileExtension = fileURL.pathExtension
        var url = directory.appendingPathComponent(UUID().uuidString)
        if !fileExtension.isEmpty {
            url.appendPathExtension(fileExtension)
        }
        return url
    }
}
