#if os(iOS)
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
@main
struct VivyTermLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        VivyTermLiveActivityWidget()
    }
}
#endif
