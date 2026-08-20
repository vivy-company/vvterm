import CoreGraphics
import Foundation

/// Backing-pixel dimensions accepted by the SSH and ET wire protocols.
nonisolated struct TerminalPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init?(width: CGFloat, height: CGFloat) {
        guard width.isFinite, height.isFinite,
              width > 0, height > 0 else {
            return nil
        }

        let truncatedWidth = width.rounded(.towardZero)
        let truncatedHeight = height.rounded(.towardZero)
        guard truncatedWidth > 0, truncatedHeight > 0,
              let wireWidth = Int32(exactly: truncatedWidth),
              let wireHeight = Int32(exactly: truncatedHeight) else {
            return nil
        }

        self.width = Int(wireWidth)
        self.height = Int(wireHeight)
    }

    init?(size: CGSize) {
        self.init(width: size.width, height: size.height)
    }
}
