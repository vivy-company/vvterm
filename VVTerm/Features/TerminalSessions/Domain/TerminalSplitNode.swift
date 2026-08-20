//
//  TerminalSplitNode.swift
//  VVTerm
//
//  Split node that stores pane IDs for the split tree.
//  Each pane ID maps to a terminal instance.
//

import Foundation

// MARK: - Split Direction

nonisolated enum TerminalSplitDirection: String, Codable, Equatable, Sendable {
    case horizontal  // left | right
    case vertical    // top / bottom
}

nonisolated enum TerminalSplitPlacement: Equatable, Sendable {
    case right
    case left
    case down
    case up

    var direction: TerminalSplitDirection {
        switch self {
        case .right, .left:
            return .horizontal
        case .down, .up:
            return .vertical
        }
    }

    var insertsBeforeSource: Bool {
        switch self {
        case .left, .up:
            return true
        case .right, .down:
            return false
        }
    }
}

nonisolated enum TerminalSplitFocusDirection: Equatable, Sendable {
    case above
    case below
    case left
    case right
}

nonisolated enum TerminalSplitResizeDirection: Equatable, Sendable {
    case up
    case down
    case left
    case right

    fileprivate var splitDirection: TerminalSplitDirection {
        switch self {
        case .left, .right:
            return .horizontal
        case .up, .down:
            return .vertical
        }
    }

    fileprivate var ratioSign: Double {
        switch self {
        case .up, .left:
            return -1
        case .down, .right:
            return 1
        }
    }
}

// MARK: - Split Node

/// A split node stores pane IDs, not connection objects.
/// This allows the view hierarchy to change without losing terminal state.
nonisolated indirect enum TerminalSplitNode: Equatable, Codable, Sendable {
    case leaf(paneId: UUID)
    case split(Split)

    nonisolated struct Split: Equatable, Codable, Sendable {
        let direction: TerminalSplitDirection
        let ratio: Double  // 0.0 to 1.0, left/top percentage
        let left: TerminalSplitNode
        let right: TerminalSplitNode
    }

    nonisolated private enum CodingKeys: String, CodingKey {
        case type
        case paneId
        case split
    }

    nonisolated private enum NodeType: String, Codable {
        case leaf
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .leaf:
            let paneId = try container.decode(UUID.self, forKey: .paneId)
            self = .leaf(paneId: paneId)
        case .split:
            let split = try container.decode(Split.self, forKey: .split)
            self = .split(split)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let paneId):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(paneId, forKey: .paneId)
        case .split(let split):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }

    // MARK: - Tree Operations

    func allPaneIds() -> [UUID] {
        switch self {
        case .leaf(let paneId):
            return [paneId]
        case .split(let split):
            return split.left.allPaneIds() + split.right.allPaneIds()
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            return split.left.leafCount + split.right.leafCount
        }
    }

    var isSplit: Bool {
        if case .split = self { return true }
        return false
    }

    // MARK: - Ghostty Equalization Algorithm

    private func weight(for direction: TerminalSplitDirection) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            if split.direction == direction {
                return split.left.weight(for: direction) + split.right.weight(for: direction)
            } else {
                return 1
            }
        }
    }

    func equalized() -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let split):
            let leftWeight = split.left.weight(for: split.direction)
            let rightWeight = split.right.weight(for: split.direction)
            let totalWeight = leftWeight + rightWeight
            let newRatio = Double(leftWeight) / Double(totalWeight)

            return .split(Split(
                direction: split.direction,
                ratio: max(0.1, min(0.9, newRatio)),
                left: split.left.equalized(),
                right: split.right.equalized()
            ))
        }
    }

    func replacingPane(_ targetId: UUID, with newNode: TerminalSplitNode) -> TerminalSplitNode {
        switch self {
        case .leaf(let paneId):
            return paneId == targetId ? newNode : self
        case .split(let split):
            return .split(Split(
                direction: split.direction,
                ratio: split.ratio,
                left: split.left.replacingPane(targetId, with: newNode),
                right: split.right.replacingPane(targetId, with: newNode)
            ))
        }
    }

    func removingPane(_ targetId: UUID) -> TerminalSplitNode? {
        switch self {
        case .leaf(let paneId):
            return paneId == targetId ? nil : self
        case .split(let split):
            let newLeft = split.left.removingPane(targetId)
            let newRight = split.right.removingPane(targetId)

            if newLeft == nil {
                return newRight
            }
            if newRight == nil {
                return newLeft
            }
            return .split(Split(
                direction: split.direction,
                ratio: split.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    func withUpdatedRatio(_ newRatio: Double) -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let split):
            return .split(Split(
                direction: split.direction,
                ratio: max(0.1, min(0.9, newRatio)),
                left: split.left,
                right: split.right
            ))
        }
    }

    func replacingNode(_ oldNode: TerminalSplitNode, with newNode: TerminalSplitNode) -> TerminalSplitNode {
        if self == oldNode {
            return newNode
        }

        switch self {
        case .leaf:
            return self
        case .split(let split):
            return .split(Split(
                direction: split.direction,
                ratio: split.ratio,
                left: split.left.replacingNode(oldNode, with: newNode),
                right: split.right.replacingNode(oldNode, with: newNode)
            ))
        }
    }

    func findPane(_ paneId: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneId
        case .split(let split):
            return split.left.findPane(paneId) || split.right.findPane(paneId)
        }
    }

    func pane(before paneId: UUID) -> UUID? {
        adjacentPane(to: paneId, offset: -1)
    }

    func pane(after paneId: UUID) -> UUID? {
        adjacentPane(to: paneId, offset: 1)
    }

    func neighboringPane(
        from paneId: UUID,
        direction: TerminalSplitFocusDirection
    ) -> UUID? {
        var frames: [UUID: PaneFrame] = [:]
        collectPaneFrames(in: .unit, frames: &frames)
        guard let source = frames[paneId] else { return nil }

        return allPaneIds()
            .enumerated()
            .compactMap { order, candidateId -> NeighborCandidate? in
                guard candidateId != paneId,
                      let candidate = frames[candidateId],
                      let score = NeighborScore(
                          source: source,
                          candidate: candidate,
                          direction: direction,
                          order: order
                      ) else {
                    return nil
                }
                return NeighborCandidate(paneId: candidateId, score: score)
            }
            .min { $0.score < $1.score }?
            .paneId
    }

    func hasDivider(
        near paneId: UUID,
        direction: TerminalSplitResizeDirection
    ) -> Bool {
        guard findPane(paneId) else { return false }
        switch self {
        case .leaf:
            return false
        case .split(let split):
            let child = split.left.findPane(paneId) ? split.left : split.right
            return child.hasDivider(near: paneId, direction: direction)
                || split.direction == direction.splitDirection
        }
    }

    func movingDivider(
        near paneId: UUID,
        direction: TerminalSplitResizeDirection,
        step: Double = 0.05
    ) -> TerminalSplitNode? {
        guard step.isFinite, step > 0, findPane(paneId) else { return nil }
        return movingNearestDivider(
            near: paneId,
            splitDirection: direction.splitDirection,
            wholeLayoutStep: step,
            ratioSign: direction.ratioSign,
            containerScale: 1
        ).node
    }

    private func adjacentPane(to paneId: UUID, offset: Int) -> UUID? {
        let paneIds = allPaneIds()
        guard paneIds.count > 1,
              let index = paneIds.firstIndex(of: paneId) else {
            return nil
        }
        let nextIndex = (index + offset + paneIds.count) % paneIds.count
        return paneIds[nextIndex]
    }

    private func movingNearestDivider(
        near paneId: UUID,
        splitDirection: TerminalSplitDirection,
        wholeLayoutStep: Double,
        ratioSign: Double,
        containerScale: Double
    ) -> (node: TerminalSplitNode?, found: Bool) {
        switch self {
        case .leaf:
            return (nil, false)
        case .split(let split):
            let paneIsInLeft = split.left.findPane(paneId)
            let child = paneIsInLeft ? split.left : split.right
            let childScale: Double
            if split.direction == splitDirection {
                childScale = containerScale * (
                    paneIsInLeft ? split.ratio : 1 - split.ratio
                )
            } else {
                childScale = containerScale
            }
            let childResult = child.movingNearestDivider(
                near: paneId,
                splitDirection: splitDirection,
                wholeLayoutStep: wholeLayoutStep,
                ratioSign: ratioSign,
                containerScale: childScale
            )

            if childResult.found, let updatedChild = childResult.node {
                return (
                    .split(Split(
                        direction: split.direction,
                        ratio: split.ratio,
                        left: paneIsInLeft ? updatedChild : split.left,
                        right: paneIsInLeft ? split.right : updatedChild
                    )),
                    true
                )
            }

            guard split.direction == splitDirection else { return (nil, false) }
            guard containerScale.isFinite,
                  containerScale > 0,
                  split.ratio.isFinite else {
                return (nil, false)
            }
            let ratioDelta = ratioSign * wholeLayoutStep / containerScale
            guard ratioDelta.isFinite else { return (nil, false) }
            return (withUpdatedRatio(split.ratio + ratioDelta), true)
        }
    }

    private func collectPaneFrames(
        in frame: PaneFrame,
        frames: inout [UUID: PaneFrame]
    ) {
        switch self {
        case .leaf(let paneId):
            frames[paneId] = frame
        case .split(let split):
            switch split.direction {
            case .horizontal:
                let leftWidth = frame.width * split.ratio
                split.left.collectPaneFrames(
                    in: PaneFrame(
                        minX: frame.minX,
                        minY: frame.minY,
                        width: leftWidth,
                        height: frame.height
                    ),
                    frames: &frames
                )
                split.right.collectPaneFrames(
                    in: PaneFrame(
                        minX: frame.minX + leftWidth,
                        minY: frame.minY,
                        width: frame.width - leftWidth,
                        height: frame.height
                    ),
                    frames: &frames
                )
            case .vertical:
                let topHeight = frame.height * split.ratio
                split.left.collectPaneFrames(
                    in: PaneFrame(
                        minX: frame.minX,
                        minY: frame.minY,
                        width: frame.width,
                        height: topHeight
                    ),
                    frames: &frames
                )
                split.right.collectPaneFrames(
                    in: PaneFrame(
                        minX: frame.minX,
                        minY: frame.minY + topHeight,
                        width: frame.width,
                        height: frame.height - topHeight
                    ),
                    frames: &frames
                )
            }
        }
    }
}

nonisolated private struct PaneFrame: Sendable {
    static let unit = PaneFrame(minX: 0, minY: 0, width: 1, height: 1)

    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var midX: Double { minX + width / 2 }
    var midY: Double { minY + height / 2 }
}

nonisolated private struct NeighborCandidate: Sendable {
    let paneId: UUID
    let score: NeighborScore
}

nonisolated private struct NeighborScore: Comparable, Sendable {
    let primaryGap: Double
    let perpendicularGap: Double
    let perpendicularCenterDistance: Double
    let primaryCenterDistance: Double
    let order: Int

    init?(
        source: PaneFrame,
        candidate: PaneFrame,
        direction: TerminalSplitFocusDirection,
        order: Int
    ) {
        switch direction {
        case .above:
            guard candidate.maxY <= source.minY else { return nil }
            primaryGap = max(0, source.minY - candidate.maxY)
            perpendicularGap = Self.intervalGap(
                source.minX...source.maxX,
                candidate.minX...candidate.maxX
            )
            perpendicularCenterDistance = abs(source.midX - candidate.midX)
            primaryCenterDistance = source.midY - candidate.midY
        case .below:
            guard candidate.minY >= source.maxY else { return nil }
            primaryGap = max(0, candidate.minY - source.maxY)
            perpendicularGap = Self.intervalGap(
                source.minX...source.maxX,
                candidate.minX...candidate.maxX
            )
            perpendicularCenterDistance = abs(source.midX - candidate.midX)
            primaryCenterDistance = candidate.midY - source.midY
        case .left:
            guard candidate.maxX <= source.minX else { return nil }
            primaryGap = max(0, source.minX - candidate.maxX)
            perpendicularGap = Self.intervalGap(
                source.minY...source.maxY,
                candidate.minY...candidate.maxY
            )
            perpendicularCenterDistance = abs(source.midY - candidate.midY)
            primaryCenterDistance = source.midX - candidate.midX
        case .right:
            guard candidate.minX >= source.maxX else { return nil }
            primaryGap = max(0, candidate.minX - source.maxX)
            perpendicularGap = Self.intervalGap(
                source.minY...source.maxY,
                candidate.minY...candidate.maxY
            )
            perpendicularCenterDistance = abs(source.midY - candidate.midY)
            primaryCenterDistance = candidate.midX - source.midX
        }
        self.order = order
    }

    static func < (lhs: NeighborScore, rhs: NeighborScore) -> Bool {
        if lhs.primaryGap != rhs.primaryGap { return lhs.primaryGap < rhs.primaryGap }
        if lhs.perpendicularGap != rhs.perpendicularGap { return lhs.perpendicularGap < rhs.perpendicularGap }
        if lhs.perpendicularCenterDistance != rhs.perpendicularCenterDistance {
            return lhs.perpendicularCenterDistance < rhs.perpendicularCenterDistance
        }
        if lhs.primaryCenterDistance != rhs.primaryCenterDistance {
            return lhs.primaryCenterDistance < rhs.primaryCenterDistance
        }
        return lhs.order < rhs.order
    }

    private static func intervalGap(
        _ lhs: ClosedRange<Double>,
        _ rhs: ClosedRange<Double>
    ) -> Double {
        if lhs.overlaps(rhs) { return 0 }
        return lhs.upperBound < rhs.lowerBound
            ? rhs.lowerBound - lhs.upperBound
            : lhs.lowerBound - rhs.upperBound
    }
}
