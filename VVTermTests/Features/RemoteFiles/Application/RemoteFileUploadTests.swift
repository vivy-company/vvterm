import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileUploadTests: RemoteFileTransferTestSupport {
    @Test
    func cancelledUploadStopsBeforeWritingRemoteData() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(directoryContents: [:])
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-cancelled-upload-\(UUID().uuidString).txt")
        try? Data("cancel me".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []
        let plan = try await store.makeLocalUploadPlan(
            at: localURL,
            depth: 0,
            traversalBudget: &traversalBudget,
            byteBudget: &byteBudget,
            visitedIdentities: &visitedIdentities
        )

        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            try await store.uploadLocalTransferPlan(
                plan,
                to: "/tmp",
                using: service,
                traversalBudget: &traversalBudget
            )
        }

        task.cancel()
        gate.continuation.yield()
        gate.continuation.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(service.operations.isEmpty)
    }

    @Test
    func uploadReportsCurrentFileBeforeCompletingIt() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(directoryContents: [:])
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-progress-\(UUID().uuidString).txt")
        try Data("upload me".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        var progress: [RemoteFileBrowserStore.TransferProgress] = []
        let tracker = RemoteFileBrowserStore.TransferProgressTracker(
            totalUnitCount: 1,
            onProgress: { progress.append($0) }
        )
        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []
        let plan = try await store.makeLocalUploadPlan(
            at: localURL,
            depth: 0,
            traversalBudget: &traversalBudget,
            byteBudget: &byteBudget,
            visitedIdentities: &visitedIdentities
        )

        try await store.uploadLocalTransferPlan(
            plan,
            to: "/tmp",
            using: service,
            progressTracker: tracker,
            traversalBudget: &traversalBudget
        )

        #expect(progress.map(\.completedUnitCount) == [0, 1])
        #expect(progress.map(\.currentItemName) == [localURL.lastPathComponent, localURL.lastPathComponent])
    }

    @Test
    func localUploadPlanRejectsSymbolicLinks() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-link-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: directory) }

        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeLocalUploadPlan(
                at: link,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func localUploadPlanRejectsFilesAboveThePerFileLimit() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-limit-\(UUID().uuidString).txt")
        try Data(repeating: 0x41, count: 5).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let limits = RemoteFileTransferLimits(
            maxDepth: 1,
            maxEntries: 2,
            maxEntriesPerDirectory: 2,
            maxFileBytes: 4,
            maxAggregateBytes: 8,
            maxElapsed: .seconds(10),
            minimumFreeBytes: 2
        )
        var traversalBudget = RemoteFileTraversalBudget(limits: limits)
        var byteBudget = RemoteFileTransferByteBudget(limits: limits)
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileTransferError.self) {
            try await store.makeLocalUploadPlan(
                at: localURL,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func localUploadPlanBoundsDirectoryEnumeration() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("a.txt"))
        try Data().write(to: directory.appendingPathComponent("b.txt"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let limits = RemoteFileTransferLimits(
            maxDepth: 2,
            maxEntries: 10,
            maxEntriesPerDirectory: 1,
            maxFileBytes: 10,
            maxAggregateBytes: 10,
            maxElapsed: .seconds(10),
            minimumFreeBytes: 2
        )
        var traversalBudget = RemoteFileTraversalBudget(limits: limits)
        var byteBudget = RemoteFileTransferByteBudget(limits: limits)
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileTransferError.self) {
            try await store.makeLocalUploadPlan(
                at: directory,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func localUploadPlanRejectsRepeatedFileIdentities() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-upload-hardlink-\(UUID().uuidString)", isDirectory: true)
        let original = directory.appendingPathComponent("original.txt")
        let hardLink = directory.appendingPathComponent("linked.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("same file".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)
        defer { try? FileManager.default.removeItem(at: directory) }

        var traversalBudget = RemoteFileTraversalBudget()
        var byteBudget = RemoteFileTransferByteBudget()
        var visitedIdentities: Set<LocalFileIdentity> = []

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeLocalUploadPlan(
                at: directory,
                depth: 0,
                traversalBudget: &traversalBudget,
                byteBudget: &byteBudget,
                visitedIdentities: &visitedIdentities
            )
        }
    }

    @Test
    func uploadCapacityKeepsTheRemoteFreeSpaceReserve() throws {
        var budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 2,
                maxEntriesPerDirectory: 2,
                maxFileBytes: 100,
                maxAggregateBytes: 100,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )
        try budget.record(11)

        let capacity = RemoteFileFilesystemCapacity.known(RemoteFileFilesystemStatus(
            blockSize: 1,
            totalBlocks: 30,
            freeBlocks: 30,
            availableBlocks: 30
        ))
        #expect(throws: RemoteFileTransferError.self) {
            try budget.validateUploadCapacity(capacity)
        }
    }

    @Test
    func standardLimitsAllowFilesAbove256MiBAndTransfersAbove1GiB() throws {
        var budget = RemoteFileTransferByteBudget()
        let fileBytes = UInt64(257) * 1_024 * 1_024

        try budget.record(fileBytes)
        try budget.record(UInt64(1) * 1_024 * 1_024 * 1_024)

        #expect(budget.consumedBytes > UInt64(1) * 1_024 * 1_024 * 1_024)
    }

    @Test
    func unavailableFilesystemCapacityDoesNotBlockUpload() throws {
        var budget = RemoteFileTransferByteBudget()
        try budget.record(UInt64(2) * 1_024 * 1_024 * 1_024)

        try budget.validateUploadCapacity(.unavailable)
    }

    @Test
    func knownFilesystemCapacityReportsExactShortfall() throws {
        var budget = RemoteFileTransferByteBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 1,
                maxEntriesPerDirectory: 1,
                maxFileBytes: 1_000,
                maxAggregateBytes: 1_000,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 20
            )
        )
        try budget.record(91)
        let capacity = RemoteFileFilesystemCapacity.known(RemoteFileFilesystemStatus(
            blockSize: 1,
            totalBlocks: 100,
            freeBlocks: 100,
            availableBlocks: 100
        ))

        do {
            try budget.validateUploadCapacity(capacity)
            Issue.record("Expected the capacity check to fail")
        } catch let error as RemoteFileTransferError {
            #expect(error == .insufficientCapacity(requiredBytes: 91, availableBytes: 80))
        }
    }

    @Test
    func standardTraversalLimitsRemainBoundedButAllowLargeDirectories() {
        let limits = RemoteFileTransferLimits.standard

        #expect(limits.maxEntries >= 1_000_000)
        #expect(limits.maxEntriesPerDirectory >= 100_000)
        #expect(limits.maxDepth == 64)
    }

}

