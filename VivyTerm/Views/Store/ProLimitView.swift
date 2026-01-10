import SwiftUI

// MARK: - Pro Limit Banner

struct ProLimitBanner: View {
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Upgrade") {
                action()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

// MARK: - Pro Feature Lock

struct ProFeatureLock: View {
    let feature: String
    let description: String
    @Binding var showUpgrade: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("\(feature) is a Pro feature")
                .font(.headline)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showUpgrade = true
            } label: {
                Label("Upgrade to Pro", systemImage: "star.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Limit Reached Alert

struct LimitReachedAlert: ViewModifier {
    let limitType: LimitType
    @Binding var isPresented: Bool
    @State private var showUpgrade = false

    enum LimitType {
        case servers
        case workspaces
        case tabs

        var title: String {
            switch self {
            case .servers: return "Server Limit Reached"
            case .workspaces: return "Workspace Limit Reached"
            case .tabs: return "Tab Limit Reached"
            }
        }

        var message: String {
            switch self {
            case .servers:
                return "You've reached the limit of \(FreeTierLimits.maxServers) servers on the free plan. Upgrade to Pro for unlimited servers."
            case .workspaces:
                return "You've reached the limit of \(FreeTierLimits.maxWorkspaces) workspace on the free plan. Upgrade to Pro for unlimited workspaces."
            case .tabs:
                return "You can only have \(FreeTierLimits.maxTabs) connection at a time on the free plan. Upgrade to Pro for multiple simultaneous connections."
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(limitType.title, isPresented: $isPresented) {
                Button("Upgrade to Pro") {
                    showUpgrade = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(limitType.message)
            }
            .sheet(isPresented: $showUpgrade) {
                ProUpgradeSheet()
            }
    }
}

extension View {
    func limitReachedAlert(_ limitType: LimitReachedAlert.LimitType, isPresented: Binding<Bool>) -> some View {
        modifier(LimitReachedAlert(limitType: limitType, isPresented: isPresented))
    }
}

// MARK: - Pro Badge

struct ProBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(compact ? .caption2 : .caption)
            if !compact {
                Text("PRO")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2)
        .background(.orange, in: Capsule())
    }
}

// MARK: - Pro Gate View

struct ProGateView<Content: View, LockedContent: View>: View {
    @ObservedObject private var storeManager = StoreManager.shared
    let content: () -> Content
    let lockedContent: () -> LockedContent

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder lockedContent: @escaping () -> LockedContent
    ) {
        self.content = content
        self.lockedContent = lockedContent
    }

    var body: some View {
        if storeManager.isPro {
            content()
        } else {
            lockedContent()
        }
    }
}

// MARK: - Usage Indicator

struct UsageIndicator: View {
    let current: Int
    let limit: Int
    let label: String
    @Binding var showUpgrade: Bool

    var isAtLimit: Bool { current >= limit }

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)

            Spacer()

            HStack(spacing: 4) {
                Text("\(current)/\(limit)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isAtLimit ? .orange : .secondary)

                if isAtLimit {
                    Button {
                        showUpgrade = true
                    } label: {
                        ProBadge(compact: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Locked Item Alert (for downgraded users)

struct LockedItemAlert: ViewModifier {
    let itemType: ItemType
    let itemName: String
    @Binding var isPresented: Bool
    @State private var showUpgrade = false

    enum ItemType {
        case server
        case workspace

        var title: String {
            switch self {
            case .server: return "Server Locked"
            case .workspace: return "Workspace Locked"
            }
        }

        var message: String {
            switch self {
            case .server:
                return "This server exceeds your free plan limit of \(FreeTierLimits.maxServers) servers. Renew your Pro subscription to access all your servers."
            case .workspace:
                return "This workspace exceeds your free plan limit of \(FreeTierLimits.maxWorkspaces) workspace. Renew your Pro subscription to access all your workspaces."
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(itemType.title, isPresented: $isPresented) {
                Button("Renew Pro") {
                    showUpgrade = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(itemName)\" \(itemType.message)")
            }
            .sheet(isPresented: $showUpgrade) {
                ProUpgradeSheet()
            }
    }
}

extension View {
    func lockedItemAlert(_ itemType: LockedItemAlert.ItemType, itemName: String, isPresented: Binding<Bool>) -> some View {
        modifier(LockedItemAlert(itemType: itemType, itemName: itemName, isPresented: isPresented))
    }
}

// MARK: - Locked Overlay Badge

struct LockedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.8), in: Capsule())
    }
}

// MARK: - Downgrade Banner (shown when user has locked items)

struct DowngradeBanner: View {
    let lockedServers: Int
    let lockedWorkspaces: Int
    let action: () -> Void

    private var message: String {
        var parts: [String] = []
        if lockedServers > 0 {
            parts.append("\(lockedServers) server\(lockedServers == 1 ? "" : "s")")
        }
        if lockedWorkspaces > 0 {
            parts.append("\(lockedWorkspaces) workspace\(lockedWorkspaces == 1 ? "" : "s")")
        }
        return parts.joined(separator: " and ") + " locked"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Subscription Expired")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Renew") {
                action()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

// MARK: - Preview

#Preview("Pro Limit Banner") {
    ProLimitBanner(
        title: "Server Limit Reached",
        message: "Upgrade to Pro for unlimited servers"
    ) {}
    .padding()
}

#Preview("Pro Feature Lock") {
    ProFeatureLock(
        feature: "Custom Environments",
        description: "Create custom environments to organize your servers beyond Production, Staging, and Development.",
        showUpgrade: .constant(false)
    )
}

#Preview("Usage Indicator") {
    VStack(spacing: 16) {
        UsageIndicator(current: 2, limit: 3, label: "Servers", showUpgrade: .constant(false))
        UsageIndicator(current: 3, limit: 3, label: "Servers", showUpgrade: .constant(false))
    }
    .padding()
}
