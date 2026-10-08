import SwiftUI
import Combine

enum NoticeTopInsetBehavior {
    case contentTop
    case safeAreaTop
}

enum NoticeBottomInsetBehavior {
    case contentBottom
    case safeAreaBottom
}

@MainActor
final class NoticeHostModel: ObservableObject {
    @Published var topBanner: NoticeItem?
    @Published private(set) var bottomOperations: [NoticeItem] = []

    private var dismissalTasks: [String: Task<Void, Never>] = [:]

    var bottomOperation: NoticeItem? {
        bottomOperations.last
    }

    func show(_ item: NoticeItem) {
        set(item, for: item.lane)
    }

    func set(_ item: NoticeItem?, for lane: NoticeLane) {
        switch lane {
        case .topBanner:
            if let currentID = topBanner?.id, currentID != item?.id {
                cancelDismissal(for: currentID)
            }
            topBanner = item
        case .bottomOperation:
            guard let item else {
                bottomOperations.forEach { cancelDismissal(for: $0.id) }
                bottomOperations.removeAll()
                return
            }

            if let index = bottomOperations.firstIndex(where: { $0.id == item.id }) {
                bottomOperations[index] = item
            } else {
                bottomOperations.append(item)
            }
        }

        guard let item else { return }

        scheduleDismissal(for: item)
    }

    private func scheduleDismissal(for item: NoticeItem) {
        cancelDismissal(for: item.id)
        if case .autoDismiss(let duration) = item.lifetime {
            dismissalTasks[item.id] = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.dismiss(id: item.id)
                }
            }
        }
    }

    private func cancelDismissal(for id: String) {
        dismissalTasks.removeValue(forKey: id)?.cancel()
    }

    func update(
        id: String,
        title: String? = nil,
        message: String? = nil,
        detail: String? = nil,
        progress: NoticeProgress? = nil,
        level: NoticeLevel? = nil,
        leading: NoticeLeading? = nil,
        lifetime: NoticeLifetime? = nil,
        action: NoticeAction? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        if var item = topBanner, item.id == id {
            item = NoticeItem(
                id: item.id,
                lane: item.lane,
                level: level ?? item.level,
                leading: leading ?? item.leading,
                title: title ?? item.title,
                message: message ?? item.message,
                detail: detail ?? item.detail,
                progress: progress ?? item.progress,
                lifetime: lifetime ?? item.lifetime,
                action: action ?? item.action,
                dismissAction: dismissAction ?? item.dismissAction
            )
            set(item, for: .topBanner)
            return
        }

        if let index = bottomOperations.firstIndex(where: { $0.id == id }) {
            var item = bottomOperations[index]
            item = NoticeItem(
                id: item.id,
                lane: item.lane,
                level: level ?? item.level,
                leading: leading ?? item.leading,
                title: title ?? item.title,
                message: message ?? item.message,
                detail: detail ?? item.detail,
                progress: progress ?? item.progress,
                lifetime: lifetime ?? item.lifetime,
                action: action ?? item.action,
                dismissAction: dismissAction ?? item.dismissAction
            )
            set(item, for: .bottomOperation)
        }
    }

    func dismiss(id: String) {
        if topBanner?.id == id {
            cancelDismissal(for: id)
            set(nil, for: .topBanner)
        } else if let index = bottomOperations.firstIndex(where: { $0.id == id }) {
            cancelDismissal(for: id)
            bottomOperations.remove(at: index)
        }
    }
}

struct NoticeHost<Content: View>: View {
    let topBanner: NoticeItem?
    let bottomOperations: [NoticeItem]
    var topInsetBehavior: NoticeTopInsetBehavior = .contentTop
    var bottomInsetBehavior: NoticeBottomInsetBehavior = .safeAreaBottom
    var bannerSurfaceStyle: NoticeSurfaceStyle = .standard
    var operationSurfaceStyle: NoticeSurfaceStyle = .standard
    let content: Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        topBanner: NoticeItem? = nil,
        bottomOperation: NoticeItem? = nil,
        bottomOperations: [NoticeItem]? = nil,
        topInsetBehavior: NoticeTopInsetBehavior = .contentTop,
        bottomInsetBehavior: NoticeBottomInsetBehavior = .safeAreaBottom,
        bannerSurfaceStyle: NoticeSurfaceStyle = .standard,
        operationSurfaceStyle: NoticeSurfaceStyle = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.topBanner = topBanner
        self.bottomOperations = bottomOperations ?? bottomOperation.map { [$0] } ?? []
        self.topInsetBehavior = topInsetBehavior
        self.bottomInsetBehavior = bottomInsetBehavior
        self.bannerSurfaceStyle = bannerSurfaceStyle
        self.operationSurfaceStyle = operationSurfaceStyle
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let bounds = NoticeLayoutPolicy.horizontalBounds(
                        size: proxy.size, safeAreaInsets: proxy.safeAreaInsets
                    )
                    ZStack {
                        VStack(spacing: 0) {
                            if let topBanner {
                                NoticeBannerView(item: topBanner, surfaceStyle: bannerSurfaceStyle)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, topHorizontalPadding)
                                    .padding(.top, topPadding(for: proxy.safeAreaInsets))
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .allowsHitTesting(true)
                            }

                            Spacer(minLength: 0)
                        }

                        VStack(spacing: 0) {
                            Spacer(minLength: 0)

                            if !bottomOperations.isEmpty {
                                VStack(alignment: .trailing, spacing: 8) {
                                    if bottomOperations.count > 1 {
                                        operationStackCount
                                    }

                                    VStack(spacing: 10) {
                                        ForEach(visibleBottomOperations) { item in
                                            OperationNoticeView(item: item, surfaceStyle: operationSurfaceStyle)
                                                .frame(maxWidth: .infinity)
                                                .zIndex(operationZIndex(for: item))
                                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                                .allowsHitTesting(true)
                                            }
                                    }
                                }
                                .frame(maxWidth: NoticeMetrics.operationMaxWidth, alignment: .trailing)
                                .padding(.horizontal, bottomHorizontalPadding)
                                .padding(.bottom, bottomPadding(for: proxy.safeAreaInsets))
                            }
                        }
                    }
                    // The terminal can extend under system chrome. Keep notices
                    // within the remaining content width, including side bars.
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: topBanner?.id)
            .animation(.easeInOut(duration: 0.2), value: bottomOperations.map(\.id))
    }

    private var topHorizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 24
        #endif
    }

    private var topVerticalPadding: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 10
        #endif
    }

    private func topPadding(for safeAreaInsets: EdgeInsets) -> CGFloat {
        switch topInsetBehavior {
        case .contentTop:
            return topVerticalPadding
        case .safeAreaTop:
            return safeAreaInsets.top + topVerticalPadding
        }
    }

    private var bottomHorizontalPadding: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 20
        #endif
    }

    private var bottomVerticalPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 16
        #endif
    }

    private var visibleBottomOperations: [NoticeItem] {
        Array(bottomOperations.suffix(4))
    }

    private var operationStackCount: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
            Text(bottomOperations.count, format: .number)
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(operationSurfaceStyle.primaryForegroundColor)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .noticeSurface(
            style: operationSurfaceStyle,
            prominence: .emphasized,
            cornerRadius: 14,
            shadowRadius: 8,
            shadowY: 4
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bottomOperations.count, format: .number))
        .accessibilityIdentifier("vvterm.notice.operationStackCount")
    }

    private func bottomPadding(for safeAreaInsets: EdgeInsets) -> CGFloat {
        switch bottomInsetBehavior {
        case .contentBottom:
            return contentBottomPadding
        case .safeAreaBottom:
            return safeAreaInsets.bottom + bottomVerticalPadding
        }
    }

    private var contentBottomPadding: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .regular ? 52 : 10
        #else
        return bottomVerticalPadding
        #endif
    }

    private func operationZIndex(for item: NoticeItem) -> Double {
        Double(bottomOperations.firstIndex(where: { $0.id == item.id }) ?? 0)
    }
}
