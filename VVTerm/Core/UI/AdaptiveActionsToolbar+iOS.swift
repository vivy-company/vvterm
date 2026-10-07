#if os(iOS)
import SwiftUI

@available(iOS 27.1, *)
struct AdaptiveActionsToolbar<Actions: View>: ToolbarContent {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @ViewBuilder let actions: () -> Actions

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: verticalEdge == nil ? .topBarTrailing : .bottomBar) {
            actions()
        }
    }
}
#endif
