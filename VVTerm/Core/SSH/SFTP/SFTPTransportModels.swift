import Foundation

/// Neutral SFTP values returned by the SSH transport. Feature adapters map
/// these values into product-owned models and errors.
nonisolated enum SFTPFileType: Hashable, Sendable {
    case file
    case directory
    case symlink
    case other
}

nonisolated struct SFTPFileEntry: Hashable, Sendable {
    let name: String
    let path: String
    let type: SFTPFileType
    let size: UInt64?
    let modifiedAt: Date?
    let permissions: UInt32?
    let symlinkTarget: String?

    static func from(
        name: String,
        path: String,
        attributes: LIBSSH2_SFTP_ATTRIBUTES,
        symlinkTarget: String? = nil
    ) -> SFTPFileEntry {
        let flags = UInt32(attributes.flags)
        let permissionBits = UInt32(attributes.permissions)
        let size = flags & UInt32(LIBSSH2_SFTP_ATTR_SIZE) != 0
            ? UInt64(attributes.filesize)
            : nil
        let modifiedAt = flags & UInt32(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
            ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime))
            : nil
        let permissions = flags & UInt32(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
            ? permissionBits
            : nil

        return SFTPFileEntry(
            name: name,
            path: path,
            type: fileType(from: permissionBits, flags: flags),
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions,
            symlinkTarget: symlinkTarget
        )
    }

    private static func fileType(from permissions: UInt32, flags: UInt32) -> SFTPFileType {
        guard flags & UInt32(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else {
            return .other
        }

        switch permissions & UInt32(LIBSSH2_SFTP_S_IFMT) {
        case UInt32(LIBSSH2_SFTP_S_IFDIR): return .directory
        case UInt32(LIBSSH2_SFTP_S_IFLNK): return .symlink
        case UInt32(LIBSSH2_SFTP_S_IFREG): return .file
        default: return .other
        }
    }
}

nonisolated struct SFTPFilesystemStatus: Hashable, Sendable {
    let blockSize: UInt64
    let totalBlocks: UInt64
    let freeBlocks: UInt64
    let availableBlocks: UInt64
}

nonisolated enum SFTPFilesystemCapacity: Hashable, Sendable {
    case known(SFTPFilesystemStatus)
    case unavailable
}

nonisolated enum SFTPTransportError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case pathNotFound
    case disconnected
    case invalidEntryName
    case resourceLimitExceeded
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return String(localized: "Permission denied.")
        case .pathNotFound: return String(localized: "The remote path could not be found.")
        case .disconnected: return String(localized: "The remote connection was interrupted.")
        case .invalidEntryName: return String(localized: "The server returned an unsafe file name.")
        case .resourceLimitExceeded: return String(localized: "The remote file operation exceeded its safety limit.")
        case .failed(let message): return message
        }
    }
}

nonisolated enum SFTPRemotePath {
    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        let absolutePath = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        var normalized: [Substring] = []
        for component in absolutePath.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".": continue
            case "..":
                if !normalized.isEmpty { normalized.removeLast() }
            default: normalized.append(component)
            }
        }
        return "/" + normalized.joined(separator: "/")
    }

    static func appending(_ name: String, to directoryPath: String) throws -> String {
        guard isValidLeaf(name) else { throw SFTPTransportError.invalidEntryName }
        let directory = normalize(directoryPath)
        return directory == "/" ? "/" + name : directory + "/" + name
    }

    private static func isValidLeaf(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }

        let prefix = value.prefix(2)
        return !(value.count >= 2 && prefix.first?.isLetter == true && prefix.last == ":")
    }
}
