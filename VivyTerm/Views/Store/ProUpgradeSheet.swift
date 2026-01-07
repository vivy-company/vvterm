import SwiftUI
import StoreKit

// MARK: - Pro Upgrade Sheet

struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var selectedProduct: Product?

    private var features: [(icon: String, title: String, description: String, color: Color)] {
        [
            ("server.rack", "Unlimited Servers & Workspaces", "Connect to as many servers as you need", .pink),
            ("icloud", "iCloud Sync", "Sync servers across all your Apple devices", .pink),
            ("star", "All Future Features", "Get access to all new features", .orange)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // Features
            featuresSection
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // Plan Options
            VStack(spacing: 8) {
                if let monthly = storeManager.monthlyProduct {
                    PlanOptionRow(
                        product: monthly,
                        title: "Monthly",
                        subtitle: "Billed monthly",
                        badge: nil,
                        isSelected: selectedProduct?.id == monthly.id
                    ) {
                        selectedProduct = monthly
                    }
                }

                if let yearly = storeManager.yearlyProduct {
                    PlanOptionRow(
                        product: yearly,
                        title: "Yearly",
                        subtitle: "Best value - billed yearly",
                        badge: "SAVE 74%",
                        isSelected: selectedProduct?.id == yearly.id
                    ) {
                        selectedProduct = yearly
                    }
                }

                if let lifetime = storeManager.lifetimeProduct {
                    PlanOptionRow(
                        product: lifetime,
                        title: "Lifetime",
                        subtitle: "One-time purchase, forever",
                        badge: "FOREVER",
                        isSelected: selectedProduct?.id == lifetime.id
                    ) {
                        selectedProduct = lifetime
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

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
                    Text(storeManager.purchaseState == .purchasing ? "Processing..." : subscribeButtonTitle)
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
            .padding(.bottom, 12)

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
        }
        .frame(width: 420, height: 520)
        .task {
            await storeManager.loadProducts()
            selectedProduct = storeManager.yearlyProduct
        }
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
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(features, id: \.title) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(feature.color)
                        .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(feature.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Legal Footer

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Cancel anytime. Subscription auto-renews.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Link("Terms of Service", destination: URL(string: "https://vvterm.com/terms")!)
                Text("•")
                    .foregroundStyle(.tertiary)
                Link("Privacy Policy", destination: URL(string: "https://vvterm.com/privacy")!)
                Text("•")
                    .foregroundStyle(.tertiary)
                Link("Refund Policy", destination: URL(string: "https://vvterm.com/refund")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Subscribe Button Title

    private var subscribeButtonTitle: String {
        guard let product = selectedProduct else { return "Select a Plan" }
        if product.id == VivyTermProducts.proLifetime {
            return "Buy - \(product.displayPrice)"
        }
        return "Subscribe - \(product.displayPrice)"
    }
}

// MARK: - Plan Option Row

private struct PlanOptionRow: View {
    let product: Product
    let title: String
    let subtitle: String
    let badge: String?
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
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(LinearGradient(
                                            colors: [Color.orange, Color.pink],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
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
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.pink.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.pink : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ProUpgradeSheet()
}
