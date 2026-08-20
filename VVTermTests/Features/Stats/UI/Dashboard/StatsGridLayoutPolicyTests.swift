import XCTest
@testable import VVTerm

final class StatsGridLayoutPolicyTests: XCTestCase {
    func testCompactBreakpointsSelectOneTwoAndThreeColumns() {
        assertBreakpoints(
            minimumColumnWidth: 292,
            spacing: 14,
            twoColumnWidth: 598,
            threeColumnWidth: 904
        )
    }

    func testDetailedBreakpointsSelectOneTwoAndThreeColumns() {
        assertBreakpoints(
            minimumColumnWidth: 320,
            spacing: 18,
            twoColumnWidth: 658,
            threeColumnWidth: 996
        )
    }

    func testLockedDockerCompactBreakpointsUseItsWiderMinimumWithoutRetainingAColumnCount() {
        assertBreakpoints(
            minimumColumnWidth: 560,
            spacing: 14,
            twoColumnWidth: 1_134,
            threeColumnWidth: 1_708
        )

        XCTAssertEqual(columnCount(width: 1_708, minimumColumnWidth: 560, spacing: 14), 3)
        XCTAssertEqual(columnCount(width: 1_133.5, minimumColumnWidth: 560, spacing: 14), 1)
        XCTAssertEqual(columnCount(width: 1_134, minimumColumnWidth: 560, spacing: 14), 2)
    }

    func testLockedDockerDetailedBreakpointsUseItsWiderMinimum() {
        assertBreakpoints(
            minimumColumnWidth: 560,
            spacing: 18,
            twoColumnWidth: 1_138,
            threeColumnWidth: 1_716
        )
    }

    func testInvalidDimensionsResolveSafely() {
        XCTAssertEqual(columnCount(width: 0, minimumColumnWidth: 292, spacing: 14), 1)
        XCTAssertEqual(columnCount(width: -1, minimumColumnWidth: 292, spacing: 14), 1)
        XCTAssertEqual(
            StatsGridLayoutPolicy.minimumGridWidth(
                for: 0,
                minimumColumnWidth: -1,
                spacing: -1
            ),
            0
        )
    }

    private func assertBreakpoints(
        minimumColumnWidth: CGFloat,
        spacing: CGFloat,
        twoColumnWidth: CGFloat,
        threeColumnWidth: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            StatsGridLayoutPolicy.minimumGridWidth(
                for: 2,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            ),
            twoColumnWidth,
            file: file,
            line: line
        )
        XCTAssertEqual(
            StatsGridLayoutPolicy.minimumGridWidth(
                for: 3,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            ),
            threeColumnWidth,
            file: file,
            line: line
        )

        XCTAssertEqual(
            columnCount(
                width: twoColumnWidth.nextDown,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            ),
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            columnCount(width: twoColumnWidth, minimumColumnWidth: minimumColumnWidth, spacing: spacing),
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            columnCount(
                width: twoColumnWidth.nextUp,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            ),
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            columnCount(
                width: threeColumnWidth.nextDown,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            ),
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            columnCount(width: threeColumnWidth, minimumColumnWidth: minimumColumnWidth, spacing: spacing),
            3,
            file: file,
            line: line
        )
        XCTAssertEqual(
            columnCount(
                width: threeColumnWidth.nextUp,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            ),
            3,
            file: file,
            line: line
        )
    }

    private func columnCount(
        width: CGFloat,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        StatsGridLayoutPolicy.columnCount(
            for: width,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        )
    }
}
