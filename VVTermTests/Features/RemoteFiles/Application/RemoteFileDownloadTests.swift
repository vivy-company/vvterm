import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileDownloadTests: RemoteFileTransferTestSupport {
    @Test
    func boundedDownloadRemovesOversizedFallbackFile() async throws {
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data(repeating: 0x41, count: 5)
        )
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-bounded-download-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: localURL) }

        await #expect(throws: RemoteFileBrowserError.self) {
            try await service.downloadFile(at: "/remote/file", to: localURL, maxBytes: 4)
        }
        #expect(!FileManager.default.fileExists(atPath: localURL.path))
    }

    @Test
    func interruptedDownloadPreservesExistingFileAndCleansStagingFile() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("partial".utf8),
            downloadError: .disconnected
        )
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vvterm-interrupted-download-\(UUID().uuidString)",
            isDirectory: true
        )
        let localURL = directoryURL.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.downloadFileAtomically(
                at: "/remote/existing.txt",
                to: localURL,
                maxBytes: 100,
                using: service
            )
        }

        #expect(try String(contentsOf: localURL, encoding: .utf8) == "original")
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        #expect(remainingNames == ["existing.txt"])
    }

    @Test
    func downloadLimitUsesDeclaredSizeInsteadOfTheAbsoluteCap() throws {
        let budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 1,
                maxEntriesPerDirectory: 1,
                maxFileBytes: 100,
                maxAggregateBytes: 200,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )

        #expect(
            try budget.downloadLimit(reportedBytes: 7, availableCapacity: 200) == 7
        )
    }

    @Test
    func downloadLimitKeepsTheFreeSpaceReserve() {
        let budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 1,
                maxEntriesPerDirectory: 1,
                maxFileBytes: 100,
                maxAggregateBytes: 200,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )

        #expect(throws: RemoteFileTransferError.self) {
            try budget.downloadLimit(reportedBytes: 11, availableCapacity: 30)
        }
    }

    @Test
    func uniqueTransferEntriesRemovesDuplicatePaths() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let duplicate = makeEntry(name: "a.txt", path: "/tmp/a.txt")
        let unique = makeEntry(name: "b.txt", path: "/tmp/b.txt")

        let deduped = store.uniqueTransferEntries([duplicate, unique, duplicate])

        #expect(deduped.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

}

