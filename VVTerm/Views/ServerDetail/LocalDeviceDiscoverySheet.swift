import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct LocalDeviceDiscoverySheet: View {
    let onUse: (DiscoveredSSHHost) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = LocalSSHDiscoveryManager()
    #if os(macOS)
    @State private var selectedHostID: String?
    @State private var hoveredHostID: String?
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            Form {
                nearbyHostsSection
                scanningStatusSection
                helpSection
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Discover Local Devices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Rescan")) {
                        manager.rescan()
                    }
                    .disabled(manager.isScanning)
                }
            }
        }
        .task {
            manager.startScan()
        }
        .onDisappear {
            manager.stopScan()
        }
        #else
        VStack(spacing: 0) {
            DialogSheetHeader(
                title: "Discover Local Devices",
                onClose: {
                    dismiss()
                }
            )

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if manager.hosts.isEmpty {
                    discoveryEmptyState
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    nearbyHostsList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                scanningStatusPanel
            }
            .padding(10)

            Divider()

            HStack(spacing: 10) {
                Button(String(localized: "Cancel")) { dismiss() }

                Spacer(minLength: 0)

                Button(String(localized: "Rescan")) {
                    manager.rescan()
                }
                .disabled(manager.isScanning)

                Button(String(localized: "Use Selected")) {
                    if let selectedHost {
                        useHost(selectedHost)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedHost == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 580, minHeight: 400, idealHeight: 470, maxHeight: 540)
        .task {
            manager.startScan()
        }
        .onDisappear {
            manager.stopScan()
        }
        #endif
    }

    #if os(iOS)
    private var nearbyHostsSection: some View {
        Section {
            if manager.hosts.isEmpty {
                emptyHostsView
            } else {
                ForEach(manager.hosts) { host in
                    Button {
                        useHost(host)
                    } label: {
                        DiscoveryHostRow(host: host)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(String(localized: "Nearby SSH Hosts"))
        }
    }

    private var scanningStatusSection: some View {
        Section {
            HStack(spacing: 10) {
                if manager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(manager.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            sourceStatusRows
        } header: {
            Text(String(localized: "Scanning Status"))
        }
    }

    private var helpSection: some View {
        Section {
            if manager.permissionState == .denied {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label(String(localized: "Open Settings"), systemImage: "gear")
                }
            }

            Button(String(localized: "Add Manually")) {
                dismiss()
            }
        } header: {
            Text(String(localized: "No Results Help"))
        } footer: {
            Text(String(localized: "Discovery only prefills host details. Credentials are still configured in Add Server."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    #if os(macOS)
    private var nearbyHostsList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(manager.hosts) { host in
                    DiscoveryHostSwitcherRow(
                        host: host,
                        isSelected: selectedHostID == host.id,
                        isHovered: hoveredHostID == host.id,
                        onSelect: {
                            selectedHostID = host.id
                        },
                        onUse: {
                            useHost(host)
                        }
                    )
                    .onHover { hovering in
                        hoveredHostID = hovering ? host.id : nil
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var scanningStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if manager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(manager.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            sourceStatusRows
        }
    }

    private var discoveryEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No SSH Hosts"))
                .font(.headline.weight(.semibold))

            Text(String(localized: "Scan your local network to discover SSH devices, then prefill Add Server."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    @ViewBuilder
    private var sourceStatusRows: some View {
        HStack(spacing: 8) {
            statusChip(
                title: String(localized: "Bonjour"),
                active: manager.bonjourActive
            )
            statusChip(
                title: String(localized: "Port 22"),
                active: manager.probeActive
            )
        }
    }

    private var emptyHostsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "No SSH hosts discovered yet."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if manager.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    #if os(macOS)
    private var selectedHost: DiscoveredSSHHost? {
        guard let selectedHostID else { return nil }
        return manager.hosts.first(where: { $0.id == selectedHostID })
    }
    #endif

    private func useHost(_ host: DiscoveredSSHHost) {
        onUse(host)
        dismiss()
    }

    private func statusChip(title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? .green : .secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct DiscoveryHostRow: View {
    let host: DiscoveredSSHHost

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(verbatim: "\(host.host):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Array(host.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                    Text(source.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }

                if let latencyMs = host.latencyMs {
                    Text(String(format: String(localized: "%lldms"), Int64(latencyMs)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

#if os(macOS)
private struct DiscoveryHostSwitcherRow: View {
    let host: DiscoveredSSHHost
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onUse: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    private var selectedTextColor: Color {
        Color(nsColor: .selectedTextColor)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.body)
                .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? selectedTextColor : .primary)
                    .lineLimit(1)

                Text(verbatim: "\(host.host):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? selectedTextColor.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Array(host.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                    Text(source.label)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.85) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            (isSelected ? selectedTextColor.opacity(0.15) : Color.primary.opacity(0.06)),
                            in: Capsule()
                        )
                }

                if let latencyMs = host.latencyMs {
                    Text(String(format: String(localized: "%lldms"), Int64(latencyMs)))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.85) : .secondary)
                }

                if isHovered || isSelected {
                    Button {
                        onUse()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(isSelected ? selectedTextColor.opacity(0.9) : .secondary)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? selectionFillColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button(String(localized: "Use")) {
                onUse()
            }
        }
    }
}
#endif

#Preview {
    LocalDeviceDiscoverySheet(onUse: { _ in })
}
