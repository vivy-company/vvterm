import SwiftUI

// MARK: - Offline Banner

struct OfflineBanner: View {
    @ObservedObject var networkMonitor: NetworkMonitor = .shared
    @State private var isExpanded = false

    var body: some View {
        if !networkMonitor.isConnected {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.subheadline)
                    Text("No network connection")
                        .font(.subheadline)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You're currently offline. Some features may not work:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            OfflineFeatureRow(icon: "server.rack", text: "Cannot connect to servers")
                            OfflineFeatureRow(icon: "icloud.slash", text: "iCloud sync paused")
                            OfflineFeatureRow(icon: "checkmark.circle", text: "Saved servers still accessible")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .background(.orange.opacity(0.15))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.orange.opacity(0.3))
                    .frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct OfflineFeatureRow: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compact Offline Indicator

struct CompactOfflineIndicator: View {
    @ObservedObject var networkMonitor: NetworkMonitor = .shared

    var body: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                    .font(.caption2)
                Text("Offline")
                    .font(.caption2)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.15), in: Capsule())
        }
    }
}

// MARK: - Network Status Indicator

struct NetworkStatusIndicator: View {
    @ObservedObject var networkMonitor: NetworkMonitor = .shared
    var showLabel: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(networkMonitor.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            if showLabel {
                Text(networkMonitor.isConnected ? networkMonitor.connectionType.displayName : String(localized: "Offline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Network Aware View Modifier

struct NetworkAwareModifier: ViewModifier {
    @ObservedObject var networkMonitor: NetworkMonitor = .shared
    let showBanner: Bool

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if showBanner {
                OfflineBanner()
            }
            content
        }
        .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
    }
}

extension View {
    func networkAware(showBanner: Bool = true) -> some View {
        modifier(NetworkAwareModifier(showBanner: showBanner))
    }
}

// MARK: - Offline-Safe Button

struct OfflineSafeButton<Label: View>: View {
    @ObservedObject var networkMonitor: NetworkMonitor = .shared
    let requiresNetwork: Bool
    let action: () -> Void
    let label: () -> Label

    init(
        requiresNetwork: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.requiresNetwork = requiresNetwork
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            HStack {
                label()
                if requiresNetwork && !networkMonitor.isConnected {
                    Image(systemName: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(requiresNetwork && !networkMonitor.isConnected)
    }
}

// MARK: - Preview

#Preview("Offline Banner") {
    VStack {
        OfflineBanner()
        Spacer()
    }
}

#Preview("Network Indicators") {
    VStack(spacing: 20) {
        CompactOfflineIndicator()
        NetworkStatusIndicator()
        NetworkStatusIndicator(showLabel: false)
    }
    .padding()
}

#Preview("Network Aware View") {
    NavigationStack {
        List {
            Text("Server 1")
            Text("Server 2")
            Text("Server 3")
        }
        .navigationTitle("Servers")
    }
    .networkAware()
}
