#if os(iOS)
import SwiftUI
import XCTest
@testable import VVTerm

final class TerminalFloatingControlLayoutTests: XCTestCase {
    private let phoneSize = CGSize(width: 390, height: 844)
    private let phoneInsets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)

    func testAnchorBoundsPlacePrimaryControlNearSideAndBottomEdges() {
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets,
            mainButtonSize: TerminalFloatingControlLayout.radialMainButtonSize
        )

        XCTAssertEqual(bounds, CGRect(x: 58, y: 105, width: 274, height: 681))
        XCTAssertEqual(
            bounds.maxX + TerminalFloatingControlLayout.radialMainButtonSize / 2,
            phoneSize.width - 24
        )
        XCTAssertEqual(
            bounds.maxY + TerminalFloatingControlLayout.radialMainButtonSize / 2,
            phoneSize.height - 24
        )
    }

    func testSideToolbarInsetsApplyOnceToDragLimits() {
        let size = CGSize(width: 1000, height: 700)
        let insets = EdgeInsets(top: 30, leading: 20, bottom: 0, trailing: 100)
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: size,
            safeAreaInsets: insets,
            mainButtonSize: TerminalFloatingControlLayout.compactButtonSize
        )
        XCTAssertEqual(bounds.minX, 66)
        XCTAssertEqual(bounds.maxX, 854)
        XCTAssertEqual(bounds.minY, 76)
        XCTAssertEqual(bounds.maxY, 654)
        let placement = TerminalFloatingControlLayout.placement(
            for: .compact,
            anchorCenter: CGPoint(x: bounds.maxX, y: bounds.maxY),
            secondaryActionCount: 3,
            containerSize: size,
            safeAreaInsets: insets
        )
        XCTAssertLessThanOrEqual(placement.frame.maxX, size.width - insets.trailing)
        XCTAssertLessThanOrEqual(placement.frame.maxY, size.height)
    }

    func testPlacementClampsSecondaryActionCountForEachStyle() {
        let anchor = CGPoint(x: 195, y: 400)

        XCTAssertEqual(
            placement(style: .compact, anchor: anchor, count: Int.max)
                .secondaryCenters.count,
            TerminalFloatingControlPreferences.maximumCompactSecondaryActionCount
        )
        XCTAssertEqual(
            placement(style: .radial, anchor: anchor, count: Int.max)
                .secondaryCenters.count,
            TerminalFloatingControlPreferences.maximumRadialSecondaryActionCount
        )
        XCTAssertTrue(
            placement(style: .radial, anchor: anchor, count: -1)
                .secondaryCenters.isEmpty
        )
    }

    func testCenteredRadialPlacementUsesFullOrbit() {
        let anchor = CGPoint(x: 195, y: 400)
        let centers = placement(style: .radial, anchor: anchor, count: 4)
            .secondaryCenters

        assertEqual(centers[0], CGPoint(x: 195, y: 330))
        assertEqual(centers[1], CGPoint(x: 265, y: 400))
        assertEqual(centers[2], CGPoint(x: 195, y: 470))
        assertEqual(centers[3], CGPoint(x: 125, y: 400))
    }

    func testRadialPlacementKeepsSevenActionsReachableAtEveryCorner() {
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets,
            mainButtonSize: TerminalFloatingControlLayout.radialMainButtonSize
        )
        let anchors = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ]
        let visibleContent = CGRect(x: 4, y: 51, width: 382, height: 789)

        for anchor in anchors {
            let placement = placement(style: .radial, anchor: anchor, count: 7)
            XCTAssertEqual(placement.secondaryCenters.count, 7)
            XCTAssertTrue(visibleContent.contains(placement.frame))

            for center in placement.secondaryCenters {
                XCTAssertGreaterThanOrEqual(distance(anchor, center), 56)
            }
            for firstIndex in placement.secondaryCenters.indices {
                for secondIndex in placement.secondaryCenters.indices
                    where secondIndex > firstIndex {
                    XCTAssertGreaterThanOrEqual(
                        distance(
                            placement.secondaryCenters[firstIndex],
                            placement.secondaryCenters[secondIndex]
                        ),
                        52
                    )
                }
            }
        }
    }

    func testCompactPlacementFlipsActionsAboveMainButtonNearBottom() {
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets,
            mainButtonSize: TerminalFloatingControlLayout.compactButtonSize
        )
        let anchor = CGPoint(x: bounds.maxX, y: bounds.maxY)
        let placement = placement(style: .compact, anchor: anchor, count: 3)

        XCTAssertEqual(placement.secondaryCenters.map(\.y), [746, 694, 642])
        XCTAssertTrue(placement.secondaryCenters.allSatisfy { $0.y < anchor.y })
    }

    func testTinyContainerUsesOneFiniteAnchor() {
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: CGSize(width: 20, height: 10),
            safeAreaInsets: EdgeInsets(),
            mainButtonSize: TerminalFloatingControlLayout.radialMainButtonSize
        )

        XCTAssertEqual(bounds, CGRect(x: 10, y: 5, width: 0, height: 0))
        XCTAssertEqual(
            TerminalFloatingControlLayout.center(
                horizontalFraction: .nan,
                verticalFraction: .infinity,
                in: bounds
            ),
            CGPoint(x: 10, y: 5)
        )
    }

    func testNonFiniteContainerValuesDoNotEscapeAnchorBounds() {
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
            safeAreaInsets: EdgeInsets(
                top: CGFloat.infinity,
                leading: CGFloat.nan,
                bottom: -20,
                trailing: -20
            ),
            mainButtonSize: TerminalFloatingControlLayout.compactButtonSize
        )

        XCTAssertTrue(bounds.minX.isFinite)
        XCTAssertTrue(bounds.minY.isFinite)
        XCTAssertTrue(bounds.width.isFinite)
        XCTAssertTrue(bounds.height.isFinite)
    }

    func testNormalizedPositionUsesFallbackForCollapsedBounds() {
        XCTAssertEqual(
            TerminalFloatingControlLayout.normalizedPosition(
                for: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                in: CGRect(x: 10, y: 20, width: 0, height: 0)
            ),
            .init(
                horizontalFraction: TerminalFloatingControlPreferences
                    .defaultHorizontalFraction,
                verticalFraction: TerminalFloatingControlPreferences
                    .defaultVerticalFraction
            )
        )
    }

    func testHideActivationUsesVisibleSafeAreaEdges() {
        let insets = EdgeInsets(top: 47, leading: 4, bottom: 34, trailing: 6)

        XCTAssertEqual(
            TerminalFloatingControlLayout.hiddenSide(
                for: CGPoint(x: 12, y: 400),
                containerSize: phoneSize,
                safeAreaInsets: insets
            ),
            .left
        )
        XCTAssertEqual(
            TerminalFloatingControlLayout.hiddenSide(
                for: CGPoint(x: 376, y: 400),
                containerSize: phoneSize,
                safeAreaInsets: insets
            ),
            .right
        )
        XCTAssertNil(
            TerminalFloatingControlLayout.hiddenSide(
                for: CGPoint(x: 195, y: 400),
                containerSize: phoneSize,
                safeAreaInsets: insets
            )
        )
    }

    func testPredictedOutwardDragActivatesNearbyEdge() {
        let insets = EdgeInsets(top: 47, leading: 4, bottom: 34, trailing: 6)

        XCTAssertEqual(
            TerminalFloatingControlLayout.hiddenSide(
                for: CGPoint(x: 44, y: 400),
                predictedEndCenter: CGPoint(x: -20, y: 400),
                containerSize: phoneSize,
                safeAreaInsets: insets
            ),
            .left
        )
        XCTAssertEqual(
            TerminalFloatingControlLayout.hiddenSide(
                for: CGPoint(x: 350, y: 400),
                predictedEndCenter: CGPoint(x: 410, y: 400),
                containerSize: phoneSize,
                safeAreaInsets: insets
            ),
            .right
        )
    }

    func testPredictedOutwardDragDoesNotHideFromMiddle() {
        XCTAssertNil(
            TerminalFloatingControlLayout.hiddenSide(
                for: CGPoint(x: 195, y: 400),
                predictedEndCenter: CGPoint(x: -200, y: 400),
                containerSize: phoneSize,
                safeAreaInsets: phoneInsets
            )
        )
    }

    func testEdgeHandleMovesVerticallyAndStaysAttachedToItsSide() {
        let center = TerminalFloatingControlLayout.edgeHandleDragCenter(
            for: .left,
            verticalFraction: 0.5,
            translation: CGSize(width: -80, height: 120),
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets
        )

        XCTAssertEqual(center.x, 22, accuracy: 0.001)
        XCTAssertGreaterThan(center.y, phoneSize.height / 2)
    }

    func testEdgeHandleReleaseKeepsVerticalMoveHidden() {
        let release = TerminalFloatingControlLayout.edgeHandleRelease(
            for: .left,
            verticalFraction: 0.5,
            translation: CGSize(width: 8, height: 120),
            predictedEndTranslation: CGSize(width: 10, height: 150),
            style: .compact,
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets
        )

        guard case .hidden(let verticalFraction) = release else {
            return XCTFail("A vertical edge-tab drag showed the full control.")
        }
        XCTAssertGreaterThan(verticalFraction, 0.5)
    }

    func testEdgeHandleReleaseShowsControlAfterFastInwardDrag() {
        let release = TerminalFloatingControlLayout.edgeHandleRelease(
            for: .right,
            verticalFraction: 0.5,
            translation: CGSize(width: -18, height: 40),
            predictedEndTranslation: CGSize(width: -90, height: 80),
            style: .compact,
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets
        )

        guard case .visible(let position) = release else {
            return XCTFail("A fast inward edge-tab drag did not show the full control.")
        }
        XCTAssertLessThan(position.horizontalFraction, 1)
        XCTAssertGreaterThan(position.verticalFraction, 0.5)
    }

    func testCompactPreviewResetKeepsActionsSeparatedAtBottomRight() {
        let previewSize = CGSize(width: 320, height: 236)
        let bounds = TerminalFloatingControlLayout.anchorBounds(
            containerSize: previewSize,
            safeAreaInsets: EdgeInsets(),
            mainButtonSize: TerminalFloatingControlLayout.compactButtonSize
        )
        let preferredAnchor = TerminalFloatingControlLayout.center(
            horizontalFraction: 1,
            verticalFraction: TerminalFloatingControlPreferences.defaultVerticalFraction,
            in: bounds
        )
        let anchor = TerminalFloatingControlLayout.previewAnchor(
            for: .compact,
            preferredCenter: preferredAnchor,
            secondaryActionCount: 3,
            containerSize: previewSize,
            safeAreaInsets: EdgeInsets()
        )
        let placement = TerminalFloatingControlLayout.placement(
            for: .compact,
            anchorCenter: anchor,
            secondaryActionCount: 3,
            containerSize: previewSize,
            safeAreaInsets: EdgeInsets()
        )
        let centers = [placement.mainCenter] + placement.secondaryCenters

        XCTAssertTrue(CGRect(x: 4, y: 4, width: 312, height: 228).contains(placement.frame))
        XCTAssertEqual(
            placement.mainCenter.y + TerminalFloatingControlLayout.compactButtonSize / 2,
            previewSize.height - 24
        )
        for firstIndex in centers.indices {
            for secondIndex in centers.indices where secondIndex > firstIndex {
                XCTAssertGreaterThanOrEqual(
                    distance(centers[firstIndex], centers[secondIndex]),
                    TerminalFloatingControlLayout.compactButtonSize
                        + TerminalFloatingControlLayout.buttonSpacing
                )
            }
        }
    }

    func testEdgeHandleIsCompactAndVoiceStatusStaysInsideVisibleBounds() {
        XCTAssertEqual(
            TerminalFloatingControlLayout.edgeHandleSize,
            CGSize(width: 44, height: 52)
        )
        XCTAssertEqual(
            TerminalFloatingControlLayout.voiceStatusCenter(
                controlFrame: CGRect(x: 9_900, y: 9_900, width: 200, height: 200),
                panelWidth: 300,
                containerSize: phoneSize,
                safeAreaInsets: phoneInsets
            ),
            CGPoint(x: 228, y: 742)
        )
    }

    private func placement(
        style: TerminalFloatingControlPreferences.ActiveStyle,
        anchor: CGPoint,
        count: Int
    ) -> TerminalFloatingControlLayout.Placement {
        TerminalFloatingControlLayout.placement(
            for: style,
            anchorCenter: anchor,
            secondaryActionCount: count,
            containerSize: phoneSize,
            safeAreaInsets: phoneInsets
        )
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func assertEqual(
        _ first: CGPoint,
        _ second: CGPoint,
        accuracy: CGFloat = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(first.x, second.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(first.y, second.y, accuracy: accuracy, file: file, line: line)
    }
}
#endif
