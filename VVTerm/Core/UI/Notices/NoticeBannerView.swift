import SwiftUI

struct NoticeBannerView: View {
    let item: NoticeItem
    var surfaceStyle: NoticeSurfaceStyle = .standard
    @State private var isShowingDetail = false

    var body: some View {
        NoticeGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                leadingView

                VStack(alignment: .leading, spacing: item.title == nil ? 0 : 2) {
                    if let title = item.title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(surfaceStyle.primaryForegroundColor)
                            .lineLimit(1)
                    }

                    Text(item.message)
                        .font(.subheadline)
                        .foregroundStyle(surfaceStyle.secondaryForegroundColor)
                        .lineLimit(item.title == nil ? 2 : 1)
                }

                Spacer(minLength: 8)

                if item.detail != nil {
                    Button(String(localized: "Details")) {
                        isShowingDetail = true
                    }
                    .noticeSecondaryButtonStyle()
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("vvterm.notice.details")
                }

                if let action = item.action {
                    Button(action.title, role: action.role, action: action.handler)
                        .noticeSecondaryButtonStyle()
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("vvterm.notice.action.\(action.id)")
                }

                if let dismissAction = item.dismissAction {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(surfaceStyle.secondaryForegroundColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss"))
                    .accessibilityIdentifier("vvterm.notice.dismiss")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: NoticeMetrics.bannerMaxWidth, alignment: .leading)
            .noticeSurface(
                style: surfaceStyle,
                prominence: .emphasized,
                cornerRadius: NoticeMetrics.notificationCornerRadius,
                shadowRadius: 14,
                shadowY: 8
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("vvterm.notice.banner")
        }
        .sheet(isPresented: $isShowingDetail) {
            if let detail = item.detail {
                NoticeDetailView(detail: detail)
            }
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        switch resolvedLeading {
        case .none:
            EmptyView()
        case .activity:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(item.level.tintColor)
                .controlSize(.small)
        case .icon(let systemName):
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.level.tintColor)
        }
    }

    private var resolvedLeading: NoticeLeading {
        switch item.leading {
        case .none:
            return .icon(item.level.defaultIconSystemName)
        default:
            return item.leading
        }
    }

}

private struct NoticeDetailView: View {
    let detail: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("vvterm.notice.detailText")
            }
            .navigationTitle(String(localized: "Diagnostics"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("vvterm.notice.detailClose")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Clipboard.copy(detail)
                        didCopy = true
                    } label: {
                        Label(
                            didCopy ? String(localized: "Copied") : String(localized: "Copy Diagnostics"),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .accessibilityIdentifier("vvterm.notice.copyDiagnostics")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }
}
