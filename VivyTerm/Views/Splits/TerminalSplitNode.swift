//
//  TerminalSplitNode.swift
//  VivyTerm
//
//  Split node that stores pane IDs for the split tree.
//  Each pane ID maps to a terminal instance.
//

import Foundation

// MARK: - Split Direction

enum TerminalSplitDirection: String, Codable, Equatable {
    case horizontal  // left | right
    case vertical    // top / bottom
}

// MARK: - Split Node

/// A split node stores pane IDs, not connection objects.
/// This allows the view hierarchy to change without losing terminal state.
indirect enum TerminalSplitNode: Equatable, Codable {
    case leaf(paneId: UUID)
    case split(Split)

    struct Split: Equatable, Codable {
        let direction: TerminalSplitDirection
        let ratio: Double  // 0.0 to 1.0, left/top percentage
        let left: TerminalSplitNode
        let right: TerminalSplitNode
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case paneId
        case split
    }

    private enum NodeType: String, Codable {
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
}
