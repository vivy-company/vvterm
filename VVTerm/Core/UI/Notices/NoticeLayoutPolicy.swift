import SwiftUI

nonisolated enum NoticeLayoutPolicy {
    static func horizontalBounds(size: CGSize, safeAreaInsets: EdgeInsets) -> CGRect {
        let width = max(size.width, 0)
        let leading = min(max(safeAreaInsets.leading, 0), width)
        let trailing = min(max(safeAreaInsets.trailing, 0), width - leading)
        return CGRect(x: leading, y: 0, width: width - leading - trailing,
                      height: max(size.height, 0))
    }
}
