#if os(iOS)
import SwiftUI

private struct StatsSheetCloseToolbarModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let placement: StatsSheetClosePlacement

    private var closePlacement: ToolbarItemPlacement {
        switch placement {
        case .automatic, .trailing:
            return .topBarTrailing
        case .leading:
            return .topBarLeading
        }
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: closePlacement) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
    }
}

extension View {
    func statsSheetCloseToolbar(placement: StatsSheetClosePlacement = .automatic) -> some View {
        modifier(StatsSheetCloseToolbarModifier(placement: placement))
    }

    @ViewBuilder
    func statsDetailPresentation<Content: View>(
        isPresented: Binding<Bool>,
        size: CGSize = StatsPresentationSize.standard,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented) {
            content()
        }
    }

    @ViewBuilder
    func statsDetailPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        size: CGSize = StatsPresentationSize.standard,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item) { value in
            content(value)
        }
    }
}
#endif
