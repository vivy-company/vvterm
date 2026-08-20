#if os(iOS)
import SwiftUI

struct TerminalConnectionStatusView: View {
    let presentation: TerminalConnectionStatusPresentation
    let connectionAttemptID: UUID
    let surfaceStyle: NoticeSurfaceStyle
    let isActive: Bool
    let onRetry: () -> Void
    let onTrustNewHostKey: () -> Void

    @State private var dismissedIdentity: TerminalConnectionStatusPresentationIdentity?

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .sheet(isPresented: isPresented) {
                    NavigationStack {
                        sheetContent
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(action: dismissCurrentPresentation) {
                                        Image(systemName: "xmark")
                                    }
                                    .accessibilityLabel(String(localized: "Close"))
                                    .accessibilityIdentifier("vvterm.connectionStatus.close")
                                }
                            }
                    }
                    .presentationDetents([.height(sheetHeight), .large])
                    .presentationDragIndicator(.visible)
                }

            if let statusNotice {
                NoticeBannerView(item: statusNotice, surfaceStyle: surfaceStyle)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: currentIdentity) { identity in
            dismissedIdentity = TerminalConnectionStatusDismissalPolicy
                .retainedDismissedIdentity(
                    currentIdentity: identity,
                    dismissedIdentity: dismissedIdentity
                )
        }
        .animation(.easeInOut(duration: 0.2), value: statusNotice?.id)
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: {
                TerminalConnectionStatusDismissalPolicy.shouldPresent(
                    identity: currentIdentity,
                    dismissedIdentity: dismissedIdentity,
                    isActive: isActive
                )
            },
            set: { presented in
                if !presented {
                    dismissCurrentPresentation()
                }
            }
        )
    }

    private var currentIdentity: TerminalConnectionStatusPresentationIdentity? {
        TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: connectionAttemptID
        )
    }

    private func dismissCurrentPresentation() {
        dismissedIdentity = currentIdentity
    }

    private var statusNotice: NoticeItem? {
        guard isActive else { return nil }

        switch presentation {
        case .hidden:
            return nil
        case .connecting(let serverName):
            return NoticeItem(
                id: "connection-status-connecting",
                lane: .topBanner,
                level: .info,
                leading: .activity,
                message: String(
                    format: String(localized: "Connecting to %@..."),
                    serverName
                )
            )
        case .disconnected(let message):
            guard currentIdentity == dismissedIdentity else { return nil }
            return NoticeItem(
                id: "connection-status-disconnected",
                lane: .topBanner,
                level: .warning,
                leading: .icon("bolt.slash.fill"),
                title: String(localized: "Disconnected"),
                message: message ?? String(localized: "The terminal is not connected."),
                action: NoticeAction(
                    id: "reconnect",
                    title: String(localized: "Reconnect"),
                    handler: onRetry
                )
            )
        case .failed(let message, _):
            guard currentIdentity == dismissedIdentity else { return nil }
            return NoticeItem(
                id: "connection-status-failed",
                lane: .topBanner,
                level: .error,
                leading: .icon("exclamationmark.triangle.fill"),
                title: String(localized: "Connection Failed"),
                message: message,
                action: NoticeAction(
                    id: "retry",
                    title: String(localized: "Retry"),
                    handler: onRetry
                )
            )
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch presentation {
        case .hidden, .connecting:
            EmptyView()
        case .disconnected(let message):
            statusSheet(
                level: .warning,
                leading: .icon("bolt.slash.fill"),
                title: String(localized: "Disconnected"),
                message: message,
                primaryAction: NoticeAction(
                    id: "reconnect",
                    title: String(localized: "Reconnect"),
                    handler: onRetry
                )
            )
        case .failed(let message, let allowsHostKeyReplacement):
            statusSheet(
                level: .error,
                leading: .icon("exclamationmark.triangle.fill"),
                title: String(localized: "Connection Failed"),
                message: message,
                primaryAction: NoticeAction(
                    id: "retry",
                    title: String(localized: "Retry"),
                    handler: onRetry
                ),
                secondaryAction: allowsHostKeyReplacement
                    ? NoticeAction(
                        id: "trust-new-host-key",
                        title: String(localized: "Trust New Host Key"),
                        handler: onTrustNewHostKey
                    )
                    : nil
            )
        }
    }

    private func statusSheet(
        level: NoticeLevel,
        leading: NoticeLeading,
        title: String,
        message: String? = nil,
        primaryAction: NoticeAction? = nil,
        secondaryAction: NoticeAction? = nil
    ) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(level.tintColor.opacity(0.14))

                sheetLeadingView(leading, level: level)
            }
            .frame(width: 52, height: 52)

            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                if let message, !message.isEmpty {
                    ScrollView {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 132)
                }
            }
            .multilineTextAlignment(.center)

            if primaryAction != nil || secondaryAction != nil {
                VStack(spacing: 10) {
                    if let primaryAction {
                        nativeSheetButton(primaryAction, isPrimary: true)
                    }

                    if let secondaryAction {
                        nativeSheetButton(secondaryAction, isPrimary: false)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func sheetLeadingView(_ leading: NoticeLeading, level: NoticeLevel) -> some View {
        switch leading {
        case .none:
            EmptyView()
        case .activity:
            ProgressView()
                .controlSize(.large)
                .tint(level.tintColor)
        case .icon(let systemName):
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(level.tintColor)
        }
    }

    @ViewBuilder
    private func nativeSheetButton(_ action: NoticeAction, isPrimary: Bool) -> some View {
        let button = Button(role: action.role, action: action.handler) {
            Text(action.title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .controlSize(.large)

        if isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var sheetHeight: CGFloat {
        switch presentation {
        case .hidden, .connecting:
            return 1
        case .disconnected(let message):
            return message == nil ? 310 : 360
        case .failed(_, let allowsHostKeyReplacement):
            return allowsHostKeyReplacement ? 500 : 420
        }
    }
}
#endif
