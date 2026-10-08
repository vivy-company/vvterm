#if os(iOS)
import SwiftUI

extension OpenSourceLicensesView {
    var platformBody: some View {
        NavigationStack {
            OpenSourceLicensesContent(documents: documents)
                .navigationTitle(Text("Open Source & Licenses"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetDismissButton(fallbackLabel: .icon) { dismiss() }
                        .accessibilityLabel(Text("Close"))
                        .accessibilityIdentifier("vvterm.openSourceLicenses.close")
                    }
                }
        }
        .presentationDetents([.large])
        .adaptiveSoftScrollEdges()
    }
}

struct OpenSourceAcknowledgementHero: View {
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 58.0

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(.pink)
                .accessibilityHidden(true)

            Text("Thank you")
                .font(.title2.weight(.semibold))

            Text("VVTerm is built with open source. Thank you for making it possible.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vvterm.openSourceLicenses.thankYou")
    }
}
#endif
