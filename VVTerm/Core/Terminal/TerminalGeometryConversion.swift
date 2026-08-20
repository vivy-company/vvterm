import CoreGraphics

nonisolated enum TerminalGeometryConversion {
    static func gridSize(cols: Int, rows: Int) -> (cols: Int32, rows: Int32)? {
        guard cols > 0, rows > 0,
              let wireCols = Int32(exactly: cols),
              let wireRows = Int32(exactly: rows) else {
            return nil
        }

        return (wireCols, wireRows)
    }

    static func ghosttySurfaceSize(
        width: CGFloat,
        height: CGFloat
    ) -> (width: UInt32, height: UInt32)? {
        guard width.isFinite, height.isFinite else { return nil }

        let truncatedWidth = width.rounded(.towardZero)
        let truncatedHeight = height.rounded(.towardZero)
        guard truncatedWidth > 0, truncatedHeight > 0,
              let pixelWidth = UInt32(exactly: truncatedWidth),
              let pixelHeight = UInt32(exactly: truncatedHeight) else {
            return nil
        }

        return (pixelWidth, pixelHeight)
    }
}
