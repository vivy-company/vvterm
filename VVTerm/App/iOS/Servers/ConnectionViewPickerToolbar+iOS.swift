#if os(iOS)
import SwiftUI

/// Uses native toolbar items on the side without replacing the connection content.
@available(iOS 27.1, *)
struct ConnectionViewPickerToolbar: ToolbarContent {
    @Binding var selection: ConnectionViewTabID
    let tabs: [ConnectionViewTabID]
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some ToolbarContent {
        if verticalEdge != nil {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ForEach(tabs) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Label(LocalizedStringKey(tab.localizedKey), systemImage: tab.icon)
                    }
                    .labelStyle(.iconOnly)
                    .tint(selection == tab ? Color.accentColor : Color.primary)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .accessibilityIdentifier("vvterm.connectionView.\(tab.rawValue)")
                }
            }
        } else {
            ToolbarItem(placement: .principal) {
                ConnectionViewSegmentedPicker(selection: $selection, tabs: tabs)
                    .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}
#endif
