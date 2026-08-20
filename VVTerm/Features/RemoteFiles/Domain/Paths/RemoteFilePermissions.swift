import Foundation

nonisolated enum RemoteFilePermissionAudience: String, CaseIterable, Identifiable, Sendable {
    case owner
    case group
    case everyone

    var id: String { rawValue }
}

nonisolated enum RemoteFilePermissionCapability: String, CaseIterable, Identifiable, Sendable {
    case read
    case write
    case execute

    var id: String { rawValue }

    func bit(for audience: RemoteFilePermissionAudience) -> UInt32 {
        switch (audience, self) {
        case (.owner, .read):
            return UInt32(LIBSSH2_SFTP_S_IRUSR)
        case (.owner, .write):
            return UInt32(LIBSSH2_SFTP_S_IWUSR)
        case (.owner, .execute):
            return UInt32(LIBSSH2_SFTP_S_IXUSR)
        case (.group, .read):
            return UInt32(LIBSSH2_SFTP_S_IRGRP)
        case (.group, .write):
            return UInt32(LIBSSH2_SFTP_S_IWGRP)
        case (.group, .execute):
            return UInt32(LIBSSH2_SFTP_S_IXGRP)
        case (.everyone, .read):
            return UInt32(LIBSSH2_SFTP_S_IROTH)
        case (.everyone, .write):
            return UInt32(LIBSSH2_SFTP_S_IWOTH)
        case (.everyone, .execute):
            return UInt32(LIBSSH2_SFTP_S_IXOTH)
        }
    }
}

nonisolated struct RemoteFilePermissionDraft: Equatable, Sendable {
    private var bits: UInt32

    init(accessBits: UInt32) {
        bits = accessBits & 0o777
    }

    init(entry: RemoteFileEntry) {
        self.init(accessBits: entry.permissions ?? 0)
    }

    var accessBits: UInt32 {
        bits & 0o777
    }

    var octalSummary: String {
        let octal = String(accessBits, radix: 8)
        return String(repeating: "0", count: max(0, 3 - octal.count)) + octal
    }

    var symbolicSummary: String {
        RemoteFileEntry.symbolicPermissions(for: accessBits)
    }

    func isEnabled(_ capability: RemoteFilePermissionCapability, for audience: RemoteFilePermissionAudience) -> Bool {
        accessBits & capability.bit(for: audience) != 0
    }

    mutating func set(
        _ isEnabled: Bool,
        capability: RemoteFilePermissionCapability,
        for audience: RemoteFilePermissionAudience
    ) {
        let bit = capability.bit(for: audience)
        if isEnabled {
            bits |= bit
        } else {
            bits &= ~bit
        }
    }
}
