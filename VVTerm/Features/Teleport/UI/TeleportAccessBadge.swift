import SwiftUI

/// Reads local issued access. This does not check whether the server is reachable.
struct TeleportAccessBadge: View {
    let configuration: TeleportServerConfiguration
    let service: TeleportAccessService?

    private enum Access {
        case checking
        case signIn
        case expires(Date)
        case unavailable
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var access = Access.checking

    var body: some View {
        Group {
            if scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    badge(at: context.date)
                }
            } else {
                badge(at: Date())
            }
        }
        .accessibilityIdentifier("vvterm.teleport.access")
        .task(id: scenePhase == .active ? configuration : nil) {
            guard scenePhase == .active else { return }
            access = .checking
            guard let service else {
                access = .unavailable
                return
            }
            while !Task.isCancelled {
                do {
                    let summary = try await service.summary(for: configuration.profile)
                    try Task.checkCancellation()
                    if let summary,
                       summary.account == configuration.profile.account,
                       summary.clusterName == configuration.clusterName {
                        access = .expires(summary.validBefore)
                    } else {
                        access = .signIn
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    access = .unavailable
                }
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    @ViewBuilder
    private func badge(at now: Date) -> some View {
        switch access {
        case .checking:
            badgeLabel("Checking access", icon: "clock", color: .secondary)
        case .signIn:
            badgeLabel("Sign in", icon: "key", color: .secondary)
        case .expires(let expiry):
            if expiry <= now {
                badgeLabel("Access expired · Sign in", icon: "clock.badge.exclamationmark", color: .orange)
            } else {
                badgeLabel(Text("Expires in \(expiry, style: .relative)"), icon: "clock", color: .secondary)
            }
        case .unavailable:
            badgeLabel("Access unavailable", icon: "exclamationmark.circle", color: .secondary)
        }
    }

    private func badgeLabel(_ title: LocalizedStringKey, icon: String, color: Color) -> some View {
        badgeLabel(Text(title), icon: icon, color: color)
    }

    private func badgeLabel(_ title: Text, icon: String, color: Color) -> some View {
        Label { title } icon: { Image(systemName: icon) }
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
    }
}
