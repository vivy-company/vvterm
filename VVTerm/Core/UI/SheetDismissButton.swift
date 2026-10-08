import SwiftUI

struct SheetDismissButton: View {
    enum FallbackLabel {
        case text
        case icon
    }

    var title: LocalizedStringKey = "Close"
    var fallbackLabel: FallbackLabel = .text
    let action: () -> Void

    var body: some View {
        Group {
            #if os(iOS)
            if #available(iOS 26, *) {
                Button(role: .cancel, action: action)
            } else {
                if fallbackLabel == .icon {
                    Button(action: action) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(title, action: action)
                }
            }
            #else
            Button(title, action: action)
            #endif
        }
        .accessibilityLabel(Text(title))
    }
}
