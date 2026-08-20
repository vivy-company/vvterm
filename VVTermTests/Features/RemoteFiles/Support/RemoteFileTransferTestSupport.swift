import Foundation
import Testing
@testable import VVTerm

@MainActor
protocol RemoteFileTransferTestSupport {}

extension RemoteFileTransferTestSupport {
    func makeEntry(
        name: String,
        path: String,
        type: RemoteFileType = .file,
        size: UInt64? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: size,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileTransferCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class RecordingRemoteFileService: RemoteFileService {
    enum Operation: Equatable {
        case deleteFile(String)
        case deleteDirectory(String)
        case upload(String)
    }

    let directoryContents: [String: [RemoteFileEntry]]
    let statEntries: [String: RemoteFileEntry]
    let downloadData: Data
    let downloadError: RemoteFileBrowserError?
    let fileUploadError: RemoteFileBrowserError?
    let downloadGate: RemoteCopyDownloadGate?
    private(set) var operations: [Operation] = []
    private(set) var listedPaths: [String] = []
    private(set) var downloadedFileURLs: [URL] = []
    private(set) var dataUploadCount = 0
    private(set) var fileUploadCount = 0

    init(
        directoryContents: [String: [RemoteFileEntry]],
        statEntries: [String: RemoteFileEntry] = [:],
        downloadData: Data = Data(),
        downloadError: RemoteFileBrowserError? = nil,
        fileUploadError: RemoteFileBrowserError? = nil,
        downloadGate: RemoteCopyDownloadGate? = nil
    ) {
        self.directoryContents = directoryContents
        self.statEntries = statEntries
        self.downloadData = downloadData
        self.downloadError = downloadError
        self.fileUploadError = fileUploadError
        self.downloadGate = downloadGate
    }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        listedPaths.append(normalizedPath)
        return directoryContents[normalizedPath] ?? []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        guard let entry = statEntries[RemoteFilePath.normalize(path)] else {
            throw RemoteFileBrowserError.pathNotFound
        }
        return entry
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func downloadFile(at path: String, to localURL: URL, maxBytes: UInt64) async throws {
        guard UInt64(downloadData.count) <= maxBytes else {
            try? FileManager.default.removeItem(at: localURL)
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        try downloadData.write(to: localURL)
        downloadedFileURLs.append(localURL)
        if let downloadGate {
            await downloadGate.wait()
            try Task.checkCancellation()
        }
        if let downloadError {
            throw downloadError
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {
        dataUploadCount += 1
        operations.append(.upload(RemoteFilePath.normalize(remotePath)))
    }

    func upload(
        fileAt localURL: URL,
        to remotePath: String,
        expectedBytes: UInt64,
        permissions: Int32
    ) async throws {
        fileUploadCount += 1
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount == expectedBytes else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        if let fileUploadError {
            throw fileUploadError
        }
        operations.append(.upload(RemoteFilePath.normalize(remotePath)))
    }

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {
        operations.append(.deleteFile(RemoteFilePath.normalize(path)))
    }

    func deleteDirectory(at path: String) async throws {
        operations.append(.deleteDirectory(RemoteFilePath.normalize(path)))
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String {
        "/"
    }

    func fileSystemCapacity(at path: String) async throws -> RemoteFileFilesystemCapacity {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }
}

@MainActor
final class RemoteCopyDownloadGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var isStarted = false

    func wait() async {
        isStarted = true
        let continuations = startContinuations
        startContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func open() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

