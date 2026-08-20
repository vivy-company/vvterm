#if os(macOS)
import AppKit
import SwiftUI

struct StatsDetailShell<Controls: View, Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let systemImage: String
    let tint: Color
    let showsControls: Bool
    let controls: () -> Controls
    let content: () -> Content

    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.showsControls = true
        self.controls = controls
        self.content = content
    }

    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: @escaping () -> Content
    ) where Controls == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.showsControls = false
        self.controls = { EmptyView() }
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatsSheetTitle(title: title, systemImage: systemImage, tint: tint)

                Spacer(minLength: 12)

                if showsControls {
                    controls()
                }

                Button(String(localized: "Close")) {
                    close()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            content()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func close() {
        dismiss()
    }
}

private struct StatsSheetTitle: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct StatsSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct StatsSheetCloseToolbarModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let placement: StatsSheetClosePlacement

    private var closePlacement: ToolbarItemPlacement {
        switch placement {
        case .automatic, .trailing:
            return .automatic
        case .leading:
            return .cancellationAction
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
                .frame(minWidth: size.width, minHeight: size.height)
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
                .frame(minWidth: size.width, minHeight: size.height)
        }
    }
}
#endif
