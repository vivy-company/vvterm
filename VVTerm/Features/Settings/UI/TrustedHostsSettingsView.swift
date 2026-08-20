import SwiftUI

struct TrustedHostsSettingsView: View {
    @EnvironmentObject private var coordinator: KnownHostSettingsCoordinator
    @State private var resetTarget: TrustedHostResetTarget?

    var body: some View {
        Group {
            if coordinator.knownHosts.isEmpty {
                TrustedHostsEmptyView()
            } else {
                Form {
                    Section {
                        ForEach(coordinator.knownHosts) { knownHost in
                            platformHostRow(for: knownHost)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            resetTarget = .all
                        } label: {
                            Label("Reset Trusted SSH Hosts", systemImage: "trash")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.trustedHosts")
        .alert(
            resetTarget?.title ?? "",
            isPresented: resetConfirmationPresented,
            presenting: resetTarget
        ) { target in
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                reset(target)
            }
        } message: { target in
            Text(target.message)
        }
        .onAppear {
            coordinator.loadHosts()
        }
    }

    private var resetConfirmationPresented: Binding<Bool> {
        Binding(
            get: { resetTarget != nil },
            set: { isPresented in
                if !isPresented {
                    resetTarget = nil
                }
            }
        )
    }

    @ViewBuilder
    func resetAction(for knownHost: KnownHostSettingsItem) -> some View {
        Button(role: .destructive) {
            resetTarget = .host(knownHost)
        } label: {
            Label("Reset", systemImage: "trash")
        }
        .accessibilityIdentifier(
            "vvterm.settings.trustedHosts.reset.\(knownHost.id)"
        )
    }

    private func reset(_ target: TrustedHostResetTarget) {
        switch target {
        case .host(let knownHost):
            coordinator.removeKnownHost(knownHost)
        case .all:
            coordinator.removeAllKnownHosts()
        }
        resetTarget = nil
    }
}

private struct TrustedHostsEmptyView: View {
    var body: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            ContentUnavailableView(
                "No Trusted Hosts",
                systemImage: "checkmark.shield",
                description: Text("Hosts appear here after you approve their fingerprints.")
            )
        } else {
            VStack(spacing: 8) {
                Label("No Trusted Hosts", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("Hosts appear here after you approve their fingerprints.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

struct TrustedHostSettingsRow: View {
    let knownHost: KnownHostSettingsItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: knownHost.endpoint)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("Last used")
                    Text(
                        knownHost.lastSeenAt,
                        format: .dateTime
                            .year()
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vvterm.settings.trustedHosts.entry.\(knownHost.id)")
    }
}

private enum TrustedHostResetTarget: Identifiable {
    case host(KnownHostSettingsItem)
    case all

    var id: String {
        switch self {
        case .host(let knownHost):
            knownHost.id
        case .all:
            "all"
        }
    }

    var title: String {
        switch self {
        case .host:
            String(localized: "Reset Trusted Host")
        case .all:
            String(localized: "Reset Trusted SSH Hosts")
        }
    }

    var message: String {
        switch self {
        case .host(let knownHost):
            String(
                format: String(localized: "VVTerm will forget the saved SSH fingerprint for %@. Verify it again when you reconnect."),
                knownHost.endpoint
            )
        case .all:
            String(localized: "VVTerm will forget all saved SSH host fingerprints on this device. The next connection to each host will trust the key it presents.")
        }
    }
}
