#if os(iOS)
import SwiftUI

extension ServerIconChooserSheet {
    var platformBody: some View {
        NavigationStack {
            formContent
                .listStyle(.insetGrouped)
                .searchable(text: searchTextBinding, prompt: Text("Search Icons"))
                .navigationTitle("Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetDismissButton(fallbackLabel: .icon) { close() }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("vvterm.serverIcon.close")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .adaptiveSoftScrollEdges()
    }
}
#endif
