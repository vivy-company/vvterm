#if os(iOS)
import SwiftUI

struct StatsFoldAwareGrid<Content: View>: View {
    let content: (ClosedRange<CGFloat>?) -> Content
    @State private var division: ClosedRange<CGFloat>?

    var body: some View {
        if #available(iOS 27.1, *) {
            content(division)
                .onGeometryChange(for: ClosedRange<CGFloat>?.self) { geometry in
                    let region = geometry.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
                        .first { $0.frame.height > $0.frame.width }
                    guard let region else { return nil }
                    // Keep only horizontal geometry so card height changes cannot feed back into layout.
                    let lower = region.frame.minX - region.margins.leading
                    let upper = region.frame.maxX + region.margins.trailing
                    guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
                    return lower...upper
                } action: { division = $0 }
        } else {
            content(nil)
        }
    }
}
#endif
