//
//  ProSettingsView.swift
//  VivyTerm
//

import SwiftUI
import StoreKit

struct ProSettingsView: View {
    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @State private var showingPlans = false
    @State private var showingManageSubscription = false

    var body: some View {
        Form {
            // Upgrade banner (only when not Pro)
            if !storeManager.isPro {
                Section {
                    upgradeBanner
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Status") {
                HStack {
                    Text("Subscription")
                    Spacer()
                    statusBadge
                }

                if storeManager.isPro {
                    HStack {
                        Text("Plan")
                        Spacer()
                        Text(planName)
                            .foregroundStyle(.secondary)
                    }

                    if let renewalDate = storeManager.subscriptionExpirationDate {
                        HStack {
                            Text(storeManager.isLifetime ? "Purchased" : "Renews")
                            Spacer()
                            Text(renewalDate, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Show usage for free tier
                    HStack {
                        Text("Servers")
                        Spacer()
                        Text("\(serverManager.servers.count) of \(FreeTierLimits.maxServers) used")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Workspaces")
                        Spacer()
                        Text("\(serverManager.workspaces.count) of \(FreeTierLimits.maxWorkspaces) used")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Simultaneous Connections")
                        Spacer()
                        Text("\(FreeTierLimits.maxTabs) max")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if storeManager.isPro {
                Section("Features") {
                    featureRow(icon: "server.rack", title: "Unlimited Servers", enabled: true)
                    featureRow(icon: "folder", title: "Unlimited Workspaces", enabled: true)
                    featureRow(icon: "rectangle.stack", title: "Multiple Connections", enabled: true)
                    featureRow(icon: "paintbrush", title: "Custom Environments", enabled: true)
                    featureRow(icon: "icloud", title: "iCloud Sync", enabled: true)
                }
            }

            if storeManager.isPro && !storeManager.isLifetime {
                Section("Billing") {
                    Button("Manage Subscription") {
                        #if os(iOS)
                        showingManageSubscription = true
                        #else
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            NSWorkspace.shared.open(url)
                        }
                        #endif
                    }
                }
            }

            Section {
                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPlans) {
            ProUpgradeSheet()
        }
        #if os(iOS)
        .manageSubscriptionsSheet(
            isPresented: $showingManageSubscription,
            subscriptionGroupID: VivyTermProducts.subscriptionGroupId
        )
        #endif
    }

    // MARK: - Components

    @ViewBuilder
    private var statusBadge: some View {
        Text(storeManager.isPro ? "Active" : "Free Tier")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(storeManager.isPro ? .green : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((storeManager.isPro ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
    }

    private var planName: String {
        if storeManager.isLifetime {
            return "Pro Lifetime"
        }
        guard let status = storeManager.subscriptionStatus,
              case .verified(let transaction) = status.transaction else {
            return "Pro"
        }
        switch transaction.productID {
        case VivyTermProducts.proMonthly:
            return "Pro Monthly"
        case VivyTermProducts.proYearly:
            return "Pro Yearly"
        default:
            return "Pro"
        }
    }

    @ViewBuilder
    private func featureRow(icon: String, title: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? .green : .secondary)
        }
    }

    // MARK: - Upgrade Banner

    private var upgradeBanner: some View {
        Button {
            showingPlans = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.orange, Color(red: 0.95, green: 0.5, blue: 0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to VVTerm Pro")
                        .font(.headline)
                    Text("Unlimited servers & workspaces")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("View Plans")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.15))
                    )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ProSettingsView()
}
