import Foundation

nonisolated struct RemoteFileFilesystemStatus: Hashable, Sendable {
    let blockSize: UInt64
    let totalBlocks: UInt64
    let freeBlocks: UInt64
    let availableBlocks: UInt64

    var totalBytes: UInt64 {
        blockSize.saturatingMultiply(totalBlocks)
    }

    var freeBytes: UInt64 {
        blockSize.saturatingMultiply(freeBlocks)
    }

    var availableBytes: UInt64 {
        blockSize.saturatingMultiply(availableBlocks)
    }
}

nonisolated enum RemoteFileFilesystemCapacity: Hashable, Sendable {
    case known(RemoteFileFilesystemStatus)
    case unavailable

    var status: RemoteFileFilesystemStatus? {
        guard case .known(let status) = self else { return nil }
        return status
    }
}

nonisolated enum RemoteFileDirectoryPhase: Equatable, Sendable {
    case notLoaded
    case loading(requestID: UUID, hasLoadedDirectory: Bool)
    case loaded
    case failed(RemoteFileBrowserError, hasLoadedDirectory: Bool)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var hasLoadedDirectory: Bool {
        switch self {
        case .notLoaded:
            return false
        case .loading(_, let hasLoadedDirectory), .failed(_, let hasLoadedDirectory):
            return hasLoadedDirectory
        case .loaded:
            return true
        }
    }

    var error: RemoteFileBrowserError? {
        guard case .failed(let error, _) = self else { return nil }
        return error
    }

    mutating func begin(requestID: UUID) {
        self = .loading(requestID: requestID, hasLoadedDirectory: hasLoadedDirectory)
    }

    @discardableResult
    mutating func complete(requestID: UUID) -> Bool {
        guard case .loading(let currentRequestID, _) = self,
              currentRequestID == requestID else { return false }
        self = .loaded
        return true
    }

    @discardableResult
    mutating func fail(requestID: UUID, error: RemoteFileBrowserError) -> Bool {
        guard case .loading(let currentRequestID, let hasLoadedDirectory) = self,
              currentRequestID == requestID else { return false }
        self = .failed(error, hasLoadedDirectory: hasLoadedDirectory)
        return true
    }
}

nonisolated enum RemoteFileViewerPhase: Equatable, Sendable {
    case idle
    case selected(path: String)
    case loading(path: String, requestID: UUID)
    case loaded(RemoteFileViewerPayload)
    case failed(path: String, RemoteFileBrowserError)

    var selectedEntryPath: String? {
        switch self {
        case .idle:
            return nil
        case .selected(let path), .loading(let path, _), .failed(let path, _):
            return path
        case .loaded(let payload):
            return payload.entry.path
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var payload: RemoteFileViewerPayload? {
        guard case .loaded(let payload) = self else { return nil }
        return payload
    }

    var error: RemoteFileBrowserError? {
        guard case .failed(_, let error) = self else { return nil }
        return error
    }

    func isLoading(requestID: UUID) -> Bool {
        guard case .loading(_, let currentRequestID) = self else { return false }
        return currentRequestID == requestID
    }

    mutating func select(path: String) {
        self = .selected(path: path)
    }

    mutating func beginLoading(path: String, requestID: UUID) {
        self = .loading(path: path, requestID: requestID)
    }

    @discardableResult
    mutating func complete(requestID: UUID, payload: RemoteFileViewerPayload) -> Bool {
        guard case .loading(let path, let currentRequestID) = self,
              path == payload.entry.path,
              currentRequestID == requestID else { return false }
        self = .loaded(payload)
        return true
    }

    @discardableResult
    mutating func fail(requestID: UUID, error: RemoteFileBrowserError) -> Bool {
        guard case .loading(let path, let currentRequestID) = self,
              currentRequestID == requestID else { return false }
        self = .failed(path: path, error)
        return true
    }
}

nonisolated private extension UInt64 {
    func saturatingMultiply(_ other: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: other)
        return result.overflow ? .max : result.partialValue
    }
}
