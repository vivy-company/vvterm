import XCTest
@testable import VVTerm

final class TerminalSplitNodeTests: XCTestCase {
    func testAllPaneIdsPreservesLeafOrder() {
        let left = UUID()
        let right = UUID()
        let node = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneId: left),
            right: .leaf(paneId: right)
        ))

        XCTAssertEqual(node.allPaneIds(), [left, right])
        XCTAssertEqual(node.leafCount, 2)
        XCTAssertTrue(node.isSplit)
    }

    func testRemovingPaneCollapsesSingleChild() {
        let left = UUID()
        let right = UUID()
        let node = TerminalSplitNode.split(.init(
            direction: .vertical,
            ratio: 0.4,
            left: .leaf(paneId: left),
            right: .leaf(paneId: right)
        ))

        let collapsed = node.removingPane(left)

        XCTAssertEqual(collapsed, .leaf(paneId: right))
    }

    func testEqualizedUsesRelativeLeafWeightsForMatchingDirection() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        let node = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.2,
            left: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: a),
                right: .leaf(paneId: b)
            )),
            right: .leaf(paneId: c)
        ))

        guard case .split(let split) = node.equalized() else {
            return XCTFail("Expected split node")
        }

        XCTAssertEqual(split.ratio, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testPreviousAndNextPaneWrapInVisualTreeOrder() {
        let (layout, a, b, c) = makeThreePaneLayout()

        XCTAssertEqual(layout.pane(after: a), b)
        XCTAssertEqual(layout.pane(after: c), a)
        XCTAssertEqual(layout.pane(before: a), c)
        XCTAssertEqual(layout.pane(before: b), a)
    }

    func testDirectionalNavigationUsesPaneGeometry() {
        let (layout, a, b, c) = makeThreePaneLayout()

        XCTAssertEqual(layout.neighboringPane(from: a, direction: .right), b)
        XCTAssertEqual(layout.neighboringPane(from: b, direction: .left), a)
        XCTAssertEqual(layout.neighboringPane(from: b, direction: .below), c)
        XCTAssertEqual(layout.neighboringPane(from: c, direction: .above), b)
        XCTAssertNil(layout.neighboringPane(from: b, direction: .above))
        XCTAssertNil(layout.neighboringPane(from: c, direction: .right))
        XCTAssertNil(layout.neighboringPane(from: a, direction: .above))
        XCTAssertNil(layout.neighboringPane(from: a, direction: .below))
    }

    func testDividerMovementTargetsNearestCompatibleAncestor() throws {
        let (layout, _, _, c) = makeThreePaneLayout()

        let movedUp = try XCTUnwrap(layout.movingDivider(near: c, direction: .up))
        guard case .split(let movedUpRoot) = movedUp,
              case .split(let movedUpNested) = movedUpRoot.right else {
            return XCTFail("Expected nested split layout")
        }
        XCTAssertEqual(movedUpRoot.ratio, 0.4, accuracy: 0.0001)
        XCTAssertEqual(movedUpNested.ratio, 0.45, accuracy: 0.0001)

        let movedRight = try XCTUnwrap(layout.movingDivider(near: c, direction: .right))
        guard case .split(let movedRightRoot) = movedRight,
              case .split(let movedRightNested) = movedRightRoot.right else {
            return XCTFail("Expected nested split layout")
        }
        XCTAssertEqual(movedRightRoot.ratio, 0.45, accuracy: 0.0001)
        XCTAssertEqual(movedRightNested.ratio, 0.5, accuracy: 0.0001)
    }

    func testDividerMovementIsBoundedAndRequiresMatchingAncestor() throws {
        let left = UUID()
        let right = UUID()
        let layout = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.89,
            left: .leaf(paneId: left),
            right: .leaf(paneId: right)
        ))

        let bounded = try XCTUnwrap(
            layout.movingDivider(near: left, direction: .right, step: 0.5)
        )
        guard case .split(let split) = bounded else {
            return XCTFail("Expected split layout")
        }
        XCTAssertEqual(split.ratio, 0.9, accuracy: 0.0001)
        XCTAssertFalse(layout.hasDivider(near: left, direction: .up))
        XCTAssertNil(layout.movingDivider(near: left, direction: .up))
    }

    func testNestedDividerMovementUsesWholeLayoutStep() throws {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let layout = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneId: a),
            right: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: b),
                right: .leaf(paneId: c)
            ))
        ))

        let moved = try XCTUnwrap(
            layout.movingDivider(near: c, direction: .left, step: 0.05)
        )
        guard case .split(let root) = moved,
              case .split(let nested) = root.right else {
            return XCTFail("Expected nested horizontal layout")
        }

        XCTAssertEqual(root.ratio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(nested.ratio, 0.4, accuracy: 0.0001)
    }

    private func makeThreePaneLayout() -> (TerminalSplitNode, UUID, UUID, UUID) {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let layout = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.4,
            left: .leaf(paneId: a),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(paneId: b),
                right: .leaf(paneId: c)
            ))
        ))
        return (layout, a, b, c)
    }
}
