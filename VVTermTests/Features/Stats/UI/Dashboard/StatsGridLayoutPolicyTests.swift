import XCTest
@testable import VVTerm

final class StatsGridLayoutPolicyTests: XCTestCase {
    func testFoldSeparatesColumnsAtItsActualPosition() {
        let columns = StatsGridLayoutPolicy.columns(
            for: 840, minimumColumnWidth: 320, spacing: 18, division: 440...460
        )
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].minX, 0)
        XCTAssertEqual(columns[0].maxX, 431)
        XCTAssertEqual(columns[1].minX, 469)
        XCTAssertEqual(columns[1].maxX, 840)
    }

    func testFoldKeepsTwoColumnsEvenBelowNormalGridBreakpoint() {
        let columns = StatsGridLayoutPolicy.columns(
            for: 600, minimumColumnWidth: 320, spacing: 18, division: 300...320
        )
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].width, 291)
        XCTAssertEqual(columns[1].width, 271)
    }

    func testDivisionOutsideContentDoesNotAddAColumn() {
        let divisions: [ClosedRange<CGFloat>] = [-30 ... -10, 400 ... 420, 0 ... 10, 380 ... 400]
        for division in divisions {
            let columns = StatsGridLayoutPolicy.columns(
                for: 400, minimumColumnWidth: 320, spacing: 18, division: division
            )
            XCTAssertEqual(columns.count, 1)
            XCTAssertEqual(columns[0].width, 400)
        }
    }

    func testNormalGridKeepsEqualColumnsAndSpacing() {
        let columns = StatsGridLayoutPolicy.columns(
            for: 1000, minimumColumnWidth: 320, spacing: 18, division: nil
        )
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns[0].width, columns[2].width)
        XCTAssertEqual(columns[1].minX - columns[0].maxX, 18, accuracy: 0.001)
        XCTAssertEqual(columns[2].maxX, 1000, accuracy: 0.001)
    }

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
