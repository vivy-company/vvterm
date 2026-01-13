#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct VivyTermLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VivyTermActivityAttributes.self) { context in
            VivyTermLiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        AppIconView(size: 20)
                        Text("VVTerm")
                            .font(.headline)
                        StatusDot(status: context.state.status)
                    }
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        Text("\(context.state.activeCount)")
                            .font(.headline)
                        Text("active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                }
            } compactLeading: {
                AppIconView(size: 16)
            } compactTrailing: {
                Text("\(context.state.activeCount)")
                    .font(.caption)
            } minimal: {
                AppIconView(size: 16)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct VivyTermLiveActivityLockScreenView: View {
    let context: ActivityViewContext<VivyTermActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("VVTerm")
                        .font(.headline)
                    StatusDot(status: context.state.status)
                }
                Text(sessionCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var sessionCountLabel: String {
        if context.state.activeCount == 1 {
            return "1 active session"
        }
        return "\(context.state.activeCount) active sessions"
    }
}

@available(iOS 16.1, *)
private struct StatusDot: View {
    let status: VivyTermLiveActivityStatus

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .reconnecting:
            return .yellow
        case .disconnected:
            return .gray
        }
    }
}

@available(iOS 16.1, *)
private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        iconImage
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    @ViewBuilder
    private var iconImage: some View {
        Image("VivyTermLiveIcon")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
    }
}
#endif
