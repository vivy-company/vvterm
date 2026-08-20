import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileBrowserPhaseTests {
    @Test
    func staleDirectoryCompletionCannotFinishANewerRequest() {
        var phase = RemoteFileDirectoryPhase.notLoaded
        let oldRequestID = UUID()
        let newRequestID = UUID()

        phase.begin(requestID: oldRequestID)
        phase.begin(requestID: newRequestID)

        let acceptedStaleCompletion = phase.complete(requestID: oldRequestID)
        #expect(!acceptedStaleCompletion)
        #expect(phase.isLoading)
        let acceptedCurrentCompletion = phase.complete(requestID: newRequestID)
        #expect(acceptedCurrentCompletion)
        #expect(phase == .loaded)
    }

    @Test
    func refreshFailurePreservesKnowledgeOfLoadedContent() {
        var phase = RemoteFileDirectoryPhase.loaded
        let requestID = UUID()

        phase.begin(requestID: requestID)
        #expect(phase.hasLoadedDirectory)

        let acceptedFailure = phase.fail(requestID: requestID, error: .disconnected)
        #expect(acceptedFailure)
        #expect(phase.hasLoadedDirectory)
        #expect(phase.error == .disconnected)
    }

    @Test
    func stalePreviewCompletionCannotReplaceANewerSelection() {
        let oldEntry = makeEntry(path: "/tmp/old.txt")
        var phase = RemoteFileViewerPhase.idle
        let requestID = UUID()

        phase.beginLoading(path: oldEntry.path, requestID: requestID)
        phase.select(path: "/tmp/new.txt")

        let accepted = phase.complete(
            requestID: requestID,
            payload: makePayload(entry: oldEntry)
        )

        #expect(!accepted)
        #expect(phase.selectedEntryPath == "/tmp/new.txt")
        #expect(phase.payload == nil)
    }

    @Test
    func filesystemByteCountsSaturateOnOverflow() {
        let status = RemoteFileFilesystemStatus(
            blockSize: .max,
            totalBlocks: 2,
            freeBlocks: 1,
            availableBlocks: 0
        )

        #expect(status.totalBytes == UInt64.max)
        #expect(status.freeBytes == UInt64.max)
        #expect(status.availableBytes == 0)
    }

    private func makeEntry(path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            type: .file,
            size: 4,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makePayload(entry: RemoteFileEntry) -> RemoteFileViewerPayload {
        RemoteFileViewerPayload(
            previewKind: .text,
            entry: entry,
            textPreview: "test",
            previewFileURL: nil,
            isTruncated: false,
            unavailableMessage: nil,
            requiresExplicitDownload: false,
            previewByteCount: 4
        )
    }
}
