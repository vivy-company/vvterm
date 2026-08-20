import Foundation

nonisolated struct StatsPreferences: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var style: Style
    var blocks: [Block]
    var updatedAt: Date
    var lastWriterDeviceId: String

    init(
        schemaVersion: Int = Self.schemaVersion,
        style: Style,
        blocks: [Block],
        updatedAt: Date,
        lastWriterDeviceId: String
    ) {
        self.schemaVersion = schemaVersion
        self.style = style
        self.blocks = blocks
        self.updatedAt = updatedAt
        self.lastWriterDeviceId = lastWriterDeviceId
    }

    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case cardsCompact
        case cardsDetailed
        case classic

        var id: String { rawValue }
    }

    enum BlockID: String, Codable, CaseIterable, Identifiable, Sendable {
        case system
        case cpu
        case memory
        case gpu
        case network
        case storage
        case processes
        case docker

        var id: String { rawValue }
    }

    struct Block: Codable, Equatable, Identifiable, Sendable {
        var id: BlockID
        var isVisible: Bool
        var order: Int
        var updatedAt: Date
    }
}

nonisolated extension StatsPreferences {
    nonisolated static let schemaVersion = 1
    static let recordName = "statsPreferences.v1"

    static var defaultBlocks: [Block] {
        BlockID.allCases.enumerated().map { index, id in
            Block(id: id, isVisible: true, order: index, updatedAt: .distantPast)
        }
    }

    static func defaultValue(lastWriterDeviceId: String) -> StatsPreferences {
        StatsPreferences(
            style: .cardsDetailed,
            blocks: defaultBlocks,
            updatedAt: .distantPast,
            lastWriterDeviceId: lastWriterDeviceId
        )
    }

    var visibleBlocks: [BlockID] {
        orderedBlocks
            .filter(\.isVisible)
            .map(\.id)
    }

    var orderedBlocks: [Block] {
        Self.sortedBlocks(blocks)
    }

    func isBlockVisible(_ id: BlockID) -> Bool {
        blocks.first(where: { $0.id == id })?.isVisible ?? true
    }

    func normalized() -> StatsPreferences {
        var blocksByID: [BlockID: Block] = [:]
        for block in blocks {
            if let existing = blocksByID[block.id] {
                if block.updatedAt >= existing.updatedAt {
                    blocksByID[block.id] = block
                }
            } else {
                blocksByID[block.id] = block
            }
        }

        for defaultBlock in Self.defaultBlocks where blocksByID[defaultBlock.id] == nil {
            blocksByID[defaultBlock.id] = defaultBlock
        }

        var normalizedBlocks = Self.sortedBlocks(Array(blocksByID.values))
        if let systemIndex = normalizedBlocks.firstIndex(where: { $0.id == .system }) {
            normalizedBlocks[systemIndex].isVisible = true
        }

        for index in normalizedBlocks.indices {
            normalizedBlocks[index].order = index
        }

        let visibleCount = normalizedBlocks.filter(\.isVisible).count
        let finalBlocks: [Block]
        if visibleCount == 0 {
            finalBlocks = Self.defaultBlocks
        } else {
            finalBlocks = normalizedBlocks
        }

        return StatsPreferences(
            schemaVersion: max(schemaVersion, Self.schemaVersion),
            style: style,
            blocks: finalBlocks,
            updatedAt: updatedAt,
            lastWriterDeviceId: lastWriterDeviceId
        )
    }

    static func merged(local: StatsPreferences, remote: StatsPreferences) -> StatsPreferences {
        let local = local.normalized()
        let remote = remote.normalized()
        let profileWinner = local.updatedAt > remote.updatedAt ? local : remote
        let orderByID = Dictionary(uniqueKeysWithValues: profileWinner.orderedBlocks.map { ($0.id, $0.order) })
        let remoteBlocksByID = Dictionary(uniqueKeysWithValues: remote.blocks.map { ($0.id, $0) })

        let mergedBlocks = local.blocks.map { localBlock in
            guard let remoteBlock = remoteBlocksByID[localBlock.id] else {
                var block = localBlock
                block.order = orderByID[block.id] ?? block.order
                return block
            }

            var block = remoteBlock.updatedAt > localBlock.updatedAt ? remoteBlock : localBlock
            block.order = orderByID[block.id] ?? block.order
            return block
        }

        return StatsPreferences(
            schemaVersion: max(local.schemaVersion, remote.schemaVersion),
            style: profileWinner.style,
            blocks: mergedBlocks,
            updatedAt: max(local.updatedAt, remote.updatedAt),
            lastWriterDeviceId: profileWinner.lastWriterDeviceId
        )
        .normalized()
    }

    private static func sortedBlocks(_ blocks: [Block]) -> [Block] {
        blocks.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.id.rawValue < rhs.id.rawValue
            }
            return lhs.order < rhs.order
        }
    }
}
