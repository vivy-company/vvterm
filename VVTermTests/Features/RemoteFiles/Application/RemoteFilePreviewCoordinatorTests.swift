import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFilePreviewCoordinatorTests {
    @Test
    func clearViewerRemovesPreviewArtifactAndResetsState() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryStorage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: temporaryStorage
        )
        let tab = makeTab()
        let entry = makeEntry(name: "preview.txt", path: "/tmp/preview.txt")
        let previewURL = try temporaryStorage.makePreviewFileURL(for: entry)
        try Data("preview".utf8).write(to: previewURL)

        store.updateState(for: tab) { state in
            state.viewerPhase = .loaded(RemoteFileViewerPayload(
                previewKind: .text,
                entry: entry,
                textPreview: "preview",
                previewFileURL: previewURL,
                isTruncated: false,
                unavailableMessage: nil,
                requiresExplicitDownload: false,
                previewByteCount: 7
            ))
        }

        store.clearViewer(for: tab)

        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
        #expect(store.selectedEntryPath(for: tab) == nil)
        #expect(store.viewerPayload(for: tab) == nil)
        #expect(store.viewerError(for: tab) == nil)
        #expect(!store.isLoadingViewer(for: tab))
    }

    @Test
    func failedMediaValidationRemovesArtifactAndReturnsNoDecoderURL() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryStorage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: temporaryStorage
        )
        let entry = makeEntry(name: "oversized.png", path: "/tmp/oversized.png")
        let previewURL = try temporaryStorage.makePreviewFileURL(for: entry)
        try Data("rejected media".utf8).write(to: previewURL)

        let decoderURL = store.validatedPreviewURL(
            at: previewURL,
            passedValidation: false
        )

        #expect(decoderURL == nil)
        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
    }

    private func makeEntry(name: String, path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makeTab() -> RemoteFileTab {
        RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFilePreviewCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
