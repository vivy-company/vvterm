#if os(iOS)
import CoreGraphics

nonisolated enum ServerNavigationLayoutPolicy {
    static func prefersSingleColumn(availableWidth: CGFloat, isPhone: Bool) -> Bool {
        // Leave room for both the server list and the active connection.
        isPhone && availableWidth < 800
    }
}
#endif
