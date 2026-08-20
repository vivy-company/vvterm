import Foundation

struct SFTPRemoteFileService: RemoteFileService {
    let client: SSHClient

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        try await mapErrors {
            try await client.listDirectory(at: path, maxEntries: maxEntries).map(Self.mapEntry)
        }
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        try await mapErrors { Self.mapEntry(try await client.stat(at: path)) }
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        try await mapErrors { Self.mapEntry(try await client.lstat(at: path)) }
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        try await mapErrors { try await client.readFile(at: path, maxBytes: maxBytes) }
    }

    func downloadFile(at path: String, to localURL: URL, maxBytes: UInt64) async throws {
        try await mapErrors {
            try await client.downloadFile(at: path, to: localURL, maxBytes: maxBytes)
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await mapErrors {
            try await client.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func upload(
        fileAt localURL: URL,
        to remotePath: String,
        expectedBytes: UInt64,
        permissions: Int32
    ) async throws {
        try await mapErrors {
            try await client.upload(
                fileAt: localURL,
                to: remotePath,
                expectedBytes: expectedBytes,
                permissions: permissions
            )
        }
    }

    func createDirectory(at path: String, permissions: Int32) async throws {
        try await mapErrors { try await client.createDirectory(at: path, permissions: permissions) }
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        try await mapErrors { try await client.renameItem(at: sourcePath, to: destinationPath) }
    }

    func deleteFile(at path: String) async throws {
        try await mapErrors { try await client.deleteFile(at: path) }
    }

    func deleteDirectory(at path: String) async throws {
        try await mapErrors { try await client.deleteDirectory(at: path) }
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        try await mapErrors { try await client.setPermissions(at: path, permissions: permissions) }
    }

    func resolveHomeDirectory() async throws -> String {
        try await mapErrors { try await client.resolveHomeDirectory() }
    }

    func fileSystemCapacity(at path: String) async throws -> RemoteFileFilesystemCapacity {
        try await mapErrors {
            switch try await client.fileSystemCapacity(at: path) {
            case .known(let status):
                return .known(RemoteFileFilesystemStatus(
                    blockSize: status.blockSize,
                    totalBlocks: status.totalBlocks,
                    freeBlocks: status.freeBlocks,
                    availableBlocks: status.availableBlocks
                ))
            case .unavailable:
                return .unavailable
            }
        }
    }

    private func mapErrors<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as SFTPTransportError {
            throw Self.mapError(error)
        }
    }

    static func mapEntry(_ entry: SFTPFileEntry) -> RemoteFileEntry {
        RemoteFileEntry(
            name: entry.name,
            path: entry.path,
            type: mapType(entry.type),
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            permissions: entry.permissions,
            symlinkTarget: entry.symlinkTarget
        )
    }

    static func mapType(_ type: SFTPFileType) -> RemoteFileType {
        switch type {
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        case .other: return .other
        }
    }

    static func mapError(_ error: SFTPTransportError) -> RemoteFileBrowserError {
        switch error {
        case .permissionDenied: return .permissionDenied
        case .pathNotFound: return .pathNotFound
        case .disconnected: return .disconnected
        case .invalidEntryName: return .invalidEntryName
        case .resourceLimitExceeded: return .resourceLimitExceeded
        case .failed(let message): return .failed(message)
        }
    }
}
