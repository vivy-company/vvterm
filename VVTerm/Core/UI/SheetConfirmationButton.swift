import SwiftUI

struct SheetConfirmationButton: View {
    let title: LocalizedStringKey
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                #if os(iOS)
                Label(title, systemImage: "checkmark").labelStyle(.iconOnly)
                #else
                Text(title)
                #endif
            }
        }
        #if os(iOS)
        .tint(.blue)
        #endif
        .accessibilityLabel(Text(title))
    }

    private var role: ButtonRole? {
        #if os(iOS)
        if #available(iOS 26, *) { return .confirm }
        #endif
        return nil
    }
}
