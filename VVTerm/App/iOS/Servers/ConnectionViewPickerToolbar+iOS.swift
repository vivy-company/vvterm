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
            // Search can move a principal item. Keep destinations beside navigation.
            ToolbarSpacer(.fixed, placement: .topBarLeading)
            ToolbarItem(placement: .topBarLeading) {
                ConnectionViewSegmentedPicker(selection: $selection, tabs: tabs)
                    .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}
#endif
