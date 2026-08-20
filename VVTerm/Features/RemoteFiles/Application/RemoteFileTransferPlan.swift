import Foundation

nonisolated struct RemoteFileTransferLimits: Sendable {
    let maxDepth: Int
    let maxEntries: Int
    let maxEntriesPerDirectory: Int
    let maxFileBytes: UInt64
    let maxAggregateBytes: UInt64
    let maxElapsed: Duration
    let minimumFreeBytes: UInt64

    // Int64.max is a representation safety ceiling, not a product file-size limit.
    // It keeps byte counts compatible with Foundation and POSIX file APIs.
    static let standard = RemoteFileTransferLimits(
        maxDepth: 64,
        maxEntries: 1_000_000,
        maxEntriesPerDirectory: 100_000,
        maxFileBytes: UInt64(Int64.max),
        maxAggregateBytes: UInt64(Int64.max),
        maxElapsed: .seconds(86_400),
        minimumFreeBytes: 64 * 1_024 * 1_024
    )
}

nonisolated enum RemoteFileTransferError: LocalizedError, Equatable, Sendable {
    case depthLimit(maximum: Int)
    case entryLimit(maximum: Int)
    case directoryEntryLimit(maximum: Int)
    case elapsedTimeLimit
    case fileSizeLimit(maximumBytes: UInt64)
    case aggregateSizeLimit(maximumBytes: UInt64)
    case insufficientCapacity(requiredBytes: UInt64, availableBytes: UInt64)
    case byteCountOverflow

    var errorDescription: String? {
        switch self {
        case .depthLimit(let maximum):
            return String(
                format: String(localized: "The folder depth exceeds the safety limit of %lld levels."),
                Int64(maximum)
            )
        case .entryLimit(let maximum):
            return String(
                format: String(localized: "The transfer exceeds the safety limit of %lld items."),
                Int64(maximum)
            )
        case .directoryEntryLimit(let maximum):
            return String(
                format: String(localized: "A folder exceeds the safety limit of %lld direct items."),
                Int64(maximum)
            )
        case .elapsedTimeLimit:
            return String(localized: "The transfer plan exceeded its 24-hour safety limit.")
        case .fileSizeLimit(let maximumBytes):
            return String(
                format: String(localized: "The file exceeds the safety limit of %@."),
                Self.formattedByteCount(maximumBytes)
            )
        case .aggregateSizeLimit(let maximumBytes):
            return String(
                format: String(localized: "The transfer exceeds the safety limit of %@."),
                Self.formattedByteCount(maximumBytes)
            )
        case .insufficientCapacity(let requiredBytes, let availableBytes):
            return String(
                format: String(localized: "The transfer needs %@, but only %@ is available after the free-space reserve."),
                Self.formattedByteCount(requiredBytes),
                Self.formattedByteCount(availableBytes)
            )
        case .byteCountOverflow:
            return String(localized: "The transfer size cannot be represented safely.")
        }
    }

    private static func formattedByteCount(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .file)
    }
}

nonisolated struct RemoteFileTransferPlanNode: Sendable {
    let entry: RemoteFileEntry
    let children: [RemoteFileTransferPlanNode]

    var unitCount: Int {
        children.reduce(1) { $0 + $1.unitCount }
    }
}

nonisolated struct LocalFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

nonisolated struct LocalUploadPlanNode: Sendable {
    enum Kind: Sendable {
        case regularFile(byteCount: UInt64)
        case directory
    }

    let sourceURL: URL
    let name: String
    let identity: LocalFileIdentity
    let kind: Kind
    let children: [LocalUploadPlanNode]

    var unitCount: Int {
        children.reduce(1) { $0 + $1.unitCount }
    }
}

nonisolated struct RemoteFileTraversalBudget: Sendable {
    private(set) var admittedEntries = 0
    let limits: RemoteFileTransferLimits
    private let deadline: ContinuousClock.Instant

    init(limits: RemoteFileTransferLimits = .standard) {
        self.limits = limits
        deadline = ContinuousClock.now.advanced(by: limits.maxElapsed)
    }

    mutating func admit(depth: Int) throws {
        try checkTime()
        guard depth <= limits.maxDepth else {
            throw RemoteFileTransferError.depthLimit(maximum: limits.maxDepth)
        }
        guard admittedEntries < limits.maxEntries else {
            throw RemoteFileTransferError.entryLimit(maximum: limits.maxEntries)
        }
        admittedEntries += 1
    }

    mutating func directoryReadLimit() throws -> Int {
        try checkTime()
        let remaining = limits.maxEntries - admittedEntries
        guard remaining > 0 else {
            throw RemoteFileTransferError.entryLimit(maximum: limits.maxEntries)
        }
        return min(remaining, limits.maxEntriesPerDirectory)
    }

    mutating func checkTime() throws {
        guard ContinuousClock.now < deadline else {
            throw RemoteFileTransferError.elapsedTimeLimit
        }
    }
}

nonisolated struct RemoteFileTransferByteBudget: Sendable {
    private(set) var consumedBytes: UInt64 = 0
    let limits: RemoteFileTransferLimits

    init(limits: RemoteFileTransferLimits = .standard) {
        self.limits = limits
    }

    func downloadLimit(
        reportedBytes: UInt64?,
        availableCapacity: UInt64
    ) throws -> UInt64 {
        guard consumedBytes <= limits.maxAggregateBytes else {
            throw RemoteFileTransferError.byteCountOverflow
        }
        let remaining = limits.maxAggregateBytes - min(consumedBytes, limits.maxAggregateBytes)
        let storageCapacity = availableCapacity > limits.minimumFreeBytes
            ? availableCapacity - limits.minimumFreeBytes
            : 0

        if let reportedBytes {
            guard reportedBytes <= limits.maxFileBytes else {
                throw RemoteFileTransferError.fileSizeLimit(maximumBytes: limits.maxFileBytes)
            }
            guard reportedBytes <= remaining else {
                throw RemoteFileTransferError.aggregateSizeLimit(maximumBytes: limits.maxAggregateBytes)
            }
            guard reportedBytes <= storageCapacity else {
                throw RemoteFileTransferError.insufficientCapacity(
                    requiredBytes: reportedBytes,
                    availableBytes: storageCapacity
                )
            }
            return reportedBytes
        }

        let limit = min(limits.maxFileBytes, remaining, storageCapacity)
        guard limit > 0 else {
            throw RemoteFileTransferError.insufficientCapacity(
                requiredBytes: 1,
                availableBytes: storageCapacity
            )
        }
        return limit
    }

    mutating func record(_ byteCount: UInt64) throws {
        guard byteCount <= limits.maxFileBytes else {
            throw RemoteFileTransferError.fileSizeLimit(maximumBytes: limits.maxFileBytes)
        }
        guard consumedBytes <= limits.maxAggregateBytes,
              byteCount <= limits.maxAggregateBytes - consumedBytes else {
            throw RemoteFileTransferError.aggregateSizeLimit(maximumBytes: limits.maxAggregateBytes)
        }
        consumedBytes += byteCount
    }

    func validateUploadCapacity(_ capacity: RemoteFileFilesystemCapacity) throws {
        guard case .known(let status) = capacity else { return }
        let usableBytes = status.availableBytes > limits.minimumFreeBytes
            ? status.availableBytes - limits.minimumFreeBytes
            : 0
        guard consumedBytes <= usableBytes else {
            throw RemoteFileTransferError.insufficientCapacity(
                requiredBytes: consumedBytes,
                availableBytes: usableBytes
            )
        }
    }
}
