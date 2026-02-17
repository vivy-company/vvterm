import SwiftUI

/// macOS sheet header used by modal dialogs (title + close button).
struct DialogSheetHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void
    var isCloseDisabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .disabled(isCloseDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
