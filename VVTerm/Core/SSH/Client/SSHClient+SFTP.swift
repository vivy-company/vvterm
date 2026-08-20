import Foundation
import os.log

extension SSHClient {
    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [SFTPFileEntry] {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(at path: String) async throws -> SFTPFileEntry {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.stat(at: path)
    }

    func lstat(at path: String) async throws -> SFTPFileEntry {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.lstat(at: path)
    }

    func readlink(at path: String) async throws -> String {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.readlink(at: path)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.readFile(at: path, maxBytes: maxBytes, offset: offset)
    }

    func fileSystemCapacity(at path: String) async throws -> SFTPFilesystemCapacity {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.fileSystemCapacity(at: path)
    }

    func downloadFile(at path: String, to localURL: URL, maxBytes: UInt64) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }

        logger.info(
            "Starting SSH download [remote: \(path, privacy: .private(mask: .hash))] [local: \(localURL.path, privacy: .private(mask: .hash))]"
        )
        try await SSHClient.runWithDeadline(
            Self.streamTransferTimeout(for: maxBytes),
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.downloadFile(at: path, to: localURL, maxBytes: maxBytes)
        }
    }

    func writeFile(_ data: Data, to path: String, permissions: Int32 = 0o644) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        try await SSHClient.runWithDeadline(
            uploadTimeout,
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.writeFile(data, to: path, permissions: permissions)
        }
    }

    func upload(
        fileAt localURL: URL,
        to remotePath: String,
        expectedBytes: UInt64,
        permissions: Int32 = 0o644
    ) async throws {
        guard !isAborted, let session else {
            throw SSHError.notConnected
        }
        logger.info(
            "Starting streamed SSH upload [path: \(remotePath, privacy: .private(mask: .hash))] [bytes: \(expectedBytes)]"
        )
        try await SSHClient.runWithDeadline(
            Self.streamTransferTimeout(for: expectedBytes),
            onTimeout: { session.abort() }
        ) {
            try Task.checkCancellation()
            try await session.writeFile(
                from: localURL,
                to: remotePath,
                expectedBytes: expectedBytes,
                permissions: permissions
            )
        }
    }

    func resolveHomeDirectory() async throws -> String {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        return try await session.resolveHomeDirectory()
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        try await session.createDirectory(at: path, permissions: permissions)
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        try await session.setPermissions(at: path, permissions: permissions)
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        try await session.renameItem(at: sourcePath, to: destinationPath)
    }

    func deleteFile(at path: String) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        try await session.deleteFile(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        guard !isAborted, let session = session else {
            throw SFTPTransportError.disconnected
        }
        try await session.deleteDirectory(at: path)
    }
}
