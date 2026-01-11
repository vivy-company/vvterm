import SwiftUI
import StoreKit

// MARK: - Pro Upgrade Sheet

struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var selectedProduct: Product?
    @State private var showSuccess = false
    @State private var errorMessage: String?

    private var features: [(icon: String, title: String, description: String, color: Color)] {
        [
            ("server.rack", String(localized: "Unlimited Servers"), String(localized: "Add as many servers as you need (free: 3)"), .pink),
            ("folder", String(localized: "Unlimited Workspaces"), String(localized: "Organize servers into multiple workspaces (free: 1)"), .pink),
            ("square.on.square", String(localized: "Multiple Connections"), String(localized: "Open multiple terminal tabs at once (free: 1)"), .orange),
            ("tag", String(localized: "Custom Environments"), String(localized: "Create custom environment labels beyond Prod/Staging/Dev"), .orange),
            ("star", String(localized: "All Future Features"), String(localized: "Get access to every new Pro feature"), .yellow)
        ]
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            sheetContent
                .navigationTitle("VVTerm Pro")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        #else
        sheetContent
        #endif
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header with close button (macOS only)
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
            #else
            // iOS: Add some top padding since NavigationStack provides the header
            Spacer().frame(height: 8)
            #endif

            // Features
            featuresSection
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // Plan Options
            VStack(spacing: 8) {
                if let monthly = storeManager.monthlyProduct {
                    PlanOptionRow(
                        product: monthly,
                        title: String(localized: "Monthly"),
                        subtitle: String(localized: "Billed monthly"),
                        badge: nil,
                        isSelected: selectedProduct?.id == monthly.id
                    ) {
                        selectedProduct = monthly
                    }
                }

                if let yearly = storeManager.yearlyProduct {
                    PlanOptionRow(
                        product: yearly,
                        title: String(localized: "Yearly"),
                        subtitle: String(localized: "Best value - billed yearly"),
                        badge: PlanBadge(title: String(localized: "SAVE 74%"), style: .save),
                        isSelected: selectedProduct?.id == yearly.id
                    ) {
                        selectedProduct = yearly
                    }
                }

                if let lifetime = storeManager.lifetimeProduct {
                    PlanOptionRow(
                        product: lifetime,
                        title: String(localized: "Lifetime"),
                        subtitle: String(localized: "One-time purchase, forever"),
                        badge: PlanBadge(title: String(localized: "FOREVER"), style: .forever),
                        isSelected: selectedProduct?.id == lifetime.id
                    ) {
                        selectedProduct = lifetime
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)

            // Subscribe Button
            Button {
                if let product = selectedProduct {
                    Task { await storeManager.purchase(product) }
                }
            } label: {
                HStack(spacing: 8) {
                    if storeManager.purchaseState == .purchasing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Text(storeManager.purchaseState == .purchasing ? String(localized: "Processing...") : subscribeButtonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.pink, Color.orange.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(selectedProduct == nil || storeManager.purchaseState == .purchasing)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Restore Purchases
            Button("Restore Purchases") {
                Task { await storeManager.restorePurchases() }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.primary)
            .padding(.bottom, 16)

            // Legal links
            legalFooter
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            #if os(iOS)
            Spacer()
            #endif
        }
        #if os(macOS)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .task {
            await storeManager.loadProducts()
            selectedProduct = storeManager.yearlyProduct
        }
        .onChange(of: storeManager.purchaseState) { newState in
            switch newState {
            case .purchased:
                withAnimation(.easeInOut(duration: 0.3)) {
                    showSuccess = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            case .failed(let message):
                errorMessage = message
            default:
                break
            }
        }
        .overlay {
            if showSuccess {
                successOverlay
            }
        }
        .alert("Purchase Failed", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
    }

    // MARK: - Success Overlay

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)

                Text("Welcome to Pro!")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text("You now have unlimited access")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
        .transition(.opacity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VVTerm Pro")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Upgrade for unlimited features")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(features.enumerated()), id: \.element.title) { index, feature in
                HStack(spacing: 16) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(feature.color)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(feature.title)
                            .font(.body)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(feature.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)

                if index < features.count - 1 {
                    Divider()
                        .overlay(Color.primary.opacity(0.08))
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    // MARK: - Legal Footer

    private var legalFooter: some View {
        VStack(spacing: 8) {
            Text("Cancel anytime. Subscription auto-renews.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                legalLink(title: "Terms of Service", url: "https://vvterm.com/terms")
                Text("•")
                    .foregroundStyle(.tertiary)
                legalLink(title: "Privacy Policy", url: "https://vvterm.com/privacy")
                Text("•")
                    .foregroundStyle(.tertiary)
                legalLink(title: "Refund Policy", url: "https://vvterm.com/refund")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Subscribe Button Title

    private var subscribeButtonTitle: String {
        guard let product = selectedProduct else { return String(localized: "Select a Plan") }
        if product.id == VivyTermProducts.proLifetime {
            return String(localized: "Buy - \(product.displayPrice)")
        }
        return String(localized: "Subscribe - \(product.displayPrice)")
    }
}

// MARK: - Plan Option Row

private struct PlanOptionRow: View {
    let product: Product
    let title: String
    let subtitle: String
    let badge: PlanBadge?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Radio circle
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.pink : .secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        if let badge = badge {
                            Text(badge.title)
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(badgeBackground(for: badge.style))
                                )
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .adaptiveGlassRect(cornerRadius: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.pink : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PlanBadge {
    let title: String
    let style: PlanBadgeStyle
}

private enum PlanBadgeStyle {
    case save
    case forever
}

private func badgeBackground(for style: PlanBadgeStyle) -> LinearGradient {
    switch style {
    case .save:
        return LinearGradient(
            colors: [Color.orange, Color.pink],
            startPoint: .leading,
            endPoint: .trailing
        )
    case .forever:
        return LinearGradient(
            colors: [Color.blue, Color.cyan],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private extension ProUpgradeSheet {
    func legalLink(title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title)
                .underline()
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Preview

#Preview {
    ProUpgradeSheet()
}
