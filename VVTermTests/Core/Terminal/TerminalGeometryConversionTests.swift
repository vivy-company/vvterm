import CoreGraphics
import Testing
@testable import VVTerm

struct TerminalGeometryConversionTests {
    @Test
    func gridSizeAcceptsPositiveDimensionsThroughExactMaximum() throws {
        let normal = try #require(TerminalGeometryConversion.gridSize(cols: 80, rows: 24))
        #expect(normal.cols == 80)
        #expect(normal.rows == 24)

        let maximum = try #require(TerminalGeometryConversion.gridSize(
            cols: Int(Int32.max),
            rows: Int(Int32.max)
        ))
        #expect(maximum.cols == Int32.max)
        #expect(maximum.rows == Int32.max)
    }

    @Test
    func gridSizeRejectsNonPositiveAndOverflowingDimensions() {
        #expect(TerminalGeometryConversion.gridSize(cols: 0, rows: 24) == nil)
        #expect(TerminalGeometryConversion.gridSize(cols: 80, rows: -1) == nil)
        #expect(TerminalGeometryConversion.gridSize(cols: Int(Int32.max) + 1, rows: 24) == nil)
        #expect(TerminalGeometryConversion.gridSize(cols: 80, rows: Int(Int32.max) + 1) == nil)
    }

    @Test
    func ghosttySurfaceSizeTruncatesPositiveFinitePixels() throws {
        let size = try #require(TerminalGeometryConversion.ghosttySurfaceSize(
            width: 2_796.9,
            height: 1_290.2
        ))

        #expect(size.width == 2_796)
        #expect(size.height == 1_290)
    }

    @Test
    func ghosttySurfaceSizeAcceptsExactMaximumAndRejectsOverflow() throws {
        let maximum = try #require(TerminalGeometryConversion.ghosttySurfaceSize(
            width: CGFloat(UInt32.max),
            height: CGFloat(UInt32.max)
        ))
        #expect(maximum.width == UInt32.max)
        #expect(maximum.height == UInt32.max)

        let truncatedMaximum = try #require(TerminalGeometryConversion.ghosttySurfaceSize(
            width: CGFloat(UInt32.max) + 0.75,
            height: 100
        ))
        #expect(truncatedMaximum.width == UInt32.max)

        #expect(TerminalGeometryConversion.ghosttySurfaceSize(
            width: CGFloat(UInt32.max) + 1,
            height: 100
        ) == nil)
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(
            width: 100,
            height: CGFloat(UInt32.max) + 1
        ) == nil)
    }

    @Test
    func ghosttySurfaceSizeRejectsInvalidDimensions() {
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(width: 0, height: 100) == nil)
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(width: -1, height: 100) == nil)
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(width: 0.5, height: 100) == nil)
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(width: 100, height: 0.5) == nil)
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(width: .infinity, height: 100) == nil)
        #expect(TerminalGeometryConversion.ghosttySurfaceSize(width: .nan, height: 100) == nil)
    }
}
