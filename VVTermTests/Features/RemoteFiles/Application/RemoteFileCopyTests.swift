import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileCopyTests: RemoteFileTransferTestSupport {
    @Test
    func remoteCopyUsesStreamedFileUpload() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let source = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("stream me".utf8)
        )
        let destination = RecordingRemoteFileService(directoryContents: [:])
        let entry = makeEntry(
            name: "large.bin",
            path: "/source/large.bin",
            size: UInt64(source.downloadData.count)
        )
        let plan = RemoteFileTransferPlanNode(entry: entry, children: [])
        var budget = RemoteFileTransferByteBudget()

        try await store.copyRemoteTransferPlan(
            plan,
            to: "/destination",
            operationRootPath: "/destination",
            sourceService: source,
            destinationService: destination,
            progressTracker: nil,
            destinationCapacity: .unavailable,
            byteBudget: &budget
        )

        #expect(destination.dataUploadCount == 0)
        #expect(destination.fileUploadCount == 1)
    }

    @Test
    func remoteCopyRemovesTemporaryFileAfterSuccess() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-remote-copy-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        )
        let source = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("copy me".utf8)
        )
        let destination = RecordingRemoteFileService(directoryContents: [:])
        let plan = RemoteFileTransferPlanNode(
            entry: makeEntry(name: "success.txt", path: "/source/success.txt", size: 7),
            children: []
        )
        var budget = RemoteFileTransferByteBudget()

        try await store.copyRemoteTransferPlan(
            plan,
            to: "/destination",
            operationRootPath: "/destination",
            sourceService: source,
            destinationService: destination,
            progressTracker: nil,
            destinationCapacity: .unavailable,
            byteBudget: &budget
        )

        let temporaryURL = try #require(source.downloadedFileURLs.first)
        #expect(source.downloadedFileURLs.count == 1)
        #expect(destination.fileUploadCount == 1)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test
    func remoteCopyRemovesTemporaryFileAfterUploadFailure() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-remote-copy-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        )
        let source = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("copy me".utf8)
        )
        let destination = RecordingRemoteFileService(
            directoryContents: [:],
            fileUploadError: RemoteFileBrowserError.disconnected
        )
        let plan = RemoteFileTransferPlanNode(
            entry: makeEntry(name: "failure.txt", path: "/source/failure.txt", size: 7),
            children: []
        )
        var budget = RemoteFileTransferByteBudget()

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.copyRemoteTransferPlan(
                plan,
                to: "/destination",
                operationRootPath: "/destination",
                sourceService: source,
                destinationService: destination,
                progressTracker: nil,
                destinationCapacity: .unavailable,
                byteBudget: &budget
            )
        }

        let temporaryURL = try #require(source.downloadedFileURLs.first)
        #expect(source.downloadedFileURLs.count == 1)
        #expect(destination.fileUploadCount == 1)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test
    func remoteCopyRemovesTemporaryFileAfterCancellation() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-remote-copy-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let downloadGate = RemoteCopyDownloadGate()
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        )
        let source = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("copy me".utf8),
            downloadGate: downloadGate
        )
        let destination = RecordingRemoteFileService(directoryContents: [:])
        let plan = RemoteFileTransferPlanNode(
            entry: makeEntry(name: "cancel.txt", path: "/source/cancel.txt", size: 7),
            children: []
        )
        let task = Task {
            var budget = RemoteFileTransferByteBudget()
            try await store.copyRemoteTransferPlan(
                plan,
                to: "/destination",
                operationRootPath: "/destination",
                sourceService: source,
                destinationService: destination,
                progressTracker: nil,
                destinationCapacity: .unavailable,
                byteBudget: &budget
            )
        }

        await downloadGate.waitUntilStarted()
        task.cancel()
        downloadGate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let temporaryURL = try #require(source.downloadedFileURLs.first)
        #expect(source.downloadedFileURLs.count == 1)
        #expect(destination.fileUploadCount == 0)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }
}

