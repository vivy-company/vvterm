import Foundation

nonisolated enum VolumeIdentity: Codable, Hashable, Sendable {
    enum Platform: String, Codable, CaseIterable, Sendable {
        case linux
        case darwin
        case windows
        case freebsd
        case openbsd
        case netbsd
        case unknown
    }

    case stable(platform: Platform, fileSystemID: String, mountPoint: String)
    case fallback(
        platform: Platform,
        source: String,
        mountPoint: String,
        fileSystem: String
    )

    init(
        platform: Platform,
        stableIdentifier: String?,
        source: String,
        mountPoint: String,
        fileSystem: String
    ) {
        let mountPoint = Self.normalizedMountPoint(mountPoint, platform: platform)
        if let stableIdentifier = stableIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stableIdentifier.isEmpty {
            self = .stable(
                platform: platform,
                fileSystemID: stableIdentifier.lowercased(),
                mountPoint: mountPoint
            )
        } else {
            self = .fallback(
                platform: platform,
                source: source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                mountPoint: mountPoint,
                fileSystem: fileSystem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
    }

    var isStable: Bool {
        if case .stable = self { return true }
        return false
    }

    fileprivate var deterministicKey: String {
        switch self {
        case .stable(let platform, let fileSystemID, let mountPoint):
            return "0|\(platform.rawValue)|\(fileSystemID)|\(mountPoint)"
        case .fallback(let platform, let source, let mountPoint, let fileSystem):
            return "1|\(platform.rawValue)|\(source)|\(mountPoint)|\(fileSystem)"
        }
    }

    static func normalizedMountPoint(_ mountPoint: String, platform: Platform) -> String {
        let trimmed = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard platform == .windows else { return trimmed }
        return trimmed.replacingOccurrences(of: "/", with: "\\").uppercased()
    }
}

nonisolated enum VolumeKind: String, Codable, CaseIterable, Sendable {
    case physical
    case container
    case network
    case virtual
    case unknown

    static func classify(source: String, mountPoint: String, fileSystem: String) -> VolumeKind {
        let source = source.lowercased()
        let mountPoint = mountPoint.lowercased()
        let fileSystem = fileSystem.lowercased()

        if containerFileSystems.contains(fileSystem)
            || source.contains("/docker/")
            || source.contains("/containerd/")
            || mountPoint.contains("/docker/")
            || mountPoint.contains("/containerd/")
            || mountPoint.contains("/overlay2/") {
            return .container
        }

        if networkFileSystems.contains(fileSystem)
            || source.hasPrefix("//")
            || source.contains(":/") && !Self.isWindowsDrive(source) {
            return .network
        }

        if virtualFileSystems.contains(fileSystem) {
            return .virtual
        }

        if source.hasPrefix("/dev/") || isWindowsDrive(source) || isWindowsDrive(mountPoint) {
            return .physical
        }

        return .unknown
    }

    private static let containerFileSystems: Set<String> = [
        "aufs", "fuse-overlayfs", "overlay", "overlayfs"
    ]

    private static let networkFileSystems: Set<String> = [
        "9p", "afpfs", "cifs", "davfs", "fuse.sshfs", "nfs", "nfs4", "smbfs"
    ]

    private static let virtualFileSystems: Set<String> = [
        "autofs", "debugfs", "devfs", "devtmpfs", "proc", "procfs", "squashfs", "sysfs", "tmpfs"
    ]

    private static func isWindowsDrive(_ value: String) -> Bool {
        guard value.count >= 2 else { return false }
        let characters = Array(value)
        return characters[0].isLetter && characters[1] == ":"
    }
}

nonisolated enum VolumeVisibilityPolicy {
    static func normalized(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        var result: [VolumeInfo] = []
        var indexByMountKey: [String: Int] = [:]

        for volume in volumes {
            let key = volume.normalizationKey
            guard let existingIndex = indexByMountKey[key] else {
                indexByMountKey[key] = result.count
                result.append(volume)
                continue
            }

            if preferredDuplicate(volume, over: result[existingIndex]) {
                result[existingIndex] = volume
            }
        }

        return result
    }

    static func visibleVolumes(
        from volumes: [VolumeInfo],
        hiddenVolumeIDs: Set<VolumeIdentity>
    ) -> [VolumeInfo] {
        normalized(volumes).filter { !hiddenVolumeIDs.contains($0.identity) }
    }

    static func isVisibleByDefault(_ volume: VolumeInfo) -> Bool {
        volume.mountPoint == "/" || volume.kind != .container
    }

    static func hiddenVolumeIDs(
        in volumes: [VolumeInfo],
        visibilityOverrides: [VolumeIdentity: Bool]
    ) -> Set<VolumeIdentity> {
        Set(normalized(volumes).compactMap { volume in
            let isVisible = visibilityOverrides[volume.identity] ?? isVisibleByDefault(volume)
            return isVisible ? nil : volume.identity
        })
    }

    static func containerVolumeIDs(in volumes: [VolumeInfo]) -> Set<VolumeIdentity> {
        Set(normalized(volumes).filter {
            $0.kind == .container && $0.mountPoint != "/"
        }.map(\.identity))
    }

    private static func preferredDuplicate(_ candidate: VolumeInfo, over existing: VolumeInfo) -> Bool {
        if candidate.identity.isStable != existing.identity.isStable {
            return candidate.identity.isStable
        }
        if candidate.total != existing.total {
            return candidate.total > existing.total
        }
        return candidate.identity.deterministicKey < existing.identity.deterministicKey
    }
}

nonisolated struct ServerVolumeVisibilityPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    private var schemaVersion: Int
    private(set) var visibilityOverridesByServer: [String: [VolumeIdentity: Bool]] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hiddenVolumeIDsByServer
        case visibilityOverridesByServer
    }

    var requiresSchemaMigration: Bool {
        schemaVersion < Self.currentSchemaVersion
    }

    mutating func markSchemaMigrationComplete() {
        schemaVersion = Self.currentSchemaVersion
    }

    init() {
        schemaVersion = Self.currentSchemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.schemaVersion = schemaVersion

        switch schemaVersion {
        case 1:
            let hiddenVolumeIDsByServer = try container.decodeIfPresent(
                [String: Set<VolumeIdentity>].self,
                forKey: .hiddenVolumeIDsByServer
            ) ?? [:]
            visibilityOverridesByServer = hiddenVolumeIDsByServer.mapValues { hiddenVolumeIDs in
                Dictionary(uniqueKeysWithValues: hiddenVolumeIDs.map { ($0, false) })
            }
        case Self.currentSchemaVersion:
            visibilityOverridesByServer = try container.decodeIfPresent(
                [String: [VolumeIdentity: Bool]].self,
                forKey: .visibilityOverridesByServer
            ) ?? [:]
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported volume visibility schema \(schemaVersion)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(visibilityOverridesByServer, forKey: .visibilityOverridesByServer)
    }

    func visibilityOverrides(for serverID: UUID) -> [VolumeIdentity: Bool] {
        visibilityOverridesByServer[serverID.uuidString] ?? [:]
    }

    mutating func setVisibilityOverrides(
        _ overrides: [VolumeIdentity: Bool],
        for serverID: UUID
    ) {
        if overrides.isEmpty {
            visibilityOverridesByServer.removeValue(forKey: serverID.uuidString)
        } else {
            visibilityOverridesByServer[serverID.uuidString] = overrides
        }
    }
}
