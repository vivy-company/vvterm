#if os(macOS)
import SwiftUI

struct StatsFoldAwareGrid<Content: View>: View {
    let content: (ClosedRange<CGFloat>?) -> Content

    var body: some View {
        content(nil)
    }
}
#endif
