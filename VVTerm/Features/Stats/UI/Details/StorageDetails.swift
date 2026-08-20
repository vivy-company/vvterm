import CryptoKit
import Foundation
import SwiftUI

nonisolated enum StorageVolumeEditingState: Equatable, Sendable {
    case browsing
    case editing

    var isEditing: Bool { self == .editing }
}

nonisolated enum StorageVolumeListPolicy {
    static func matchingVolumes(
        _ volumes: [VolumeInfo],
        searchText: String
    ) -> [VolumeInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return VolumeVisibilityPolicy.normalized(volumes).filter { volume in
            guard !query.isEmpty else { return true }

            return volume.mountPoint.lowercased().contains(query)
                || volume.source.lowercased().contains(query)
                || volume.fileSystem.lowercased().contains(query)
        }
    }
}

nonisolated enum StorageVolumePresentationPolicy {
    static func visibleVolumes(
        from volumes: [VolumeInfo],
        hiddenVolumeIDs: Set<VolumeIdentity>
    ) -> [VolumeInfo] {
        VolumeVisibilityPolicy.visibleVolumes(
            from: volumes,
            hiddenVolumeIDs: hiddenVolumeIDs
        )
    }

    static func cardVolumes(from visibleVolumes: [VolumeInfo], limit: Int) -> [VolumeInfo] {
        Array(visibleVolumes.prefix(max(0, limit)))
    }
}

struct StorageDetailsSheet: View {
    let volumes: [VolumeInfo]
    let hiddenVolumeIDs: Set<VolumeIdentity>
    let loadStorageHealth: ((VolumeInfo) async throws -> StorageHealthResult)?
    let setVolumeVisibility: (VolumeInfo, Bool) -> Void
    let setVolumesVisibility: ([VolumeInfo], Bool) -> Void

    @State private var searchText = ""
    @State private var editingState: StorageVolumeEditingState = .browsing
    @State private var selectedHealthVolume: VolumeInfo?

    var body: some View {
        StorageDetailsPlatformShell(
            searchText: $searchText,
            controls: { toolbarControl },
            content: { volumeList }
        )
            .adaptiveSoftScrollEdges()
            .accessibilityIdentifier("vvterm.stats.storage.details")
            .statsDetailPresentation(item: $selectedHealthVolume) { volume in
                StorageHealthDetailsSheet(volume: volume, loadHealth: loadStorageHealth)
            }
    }

    private var volumeList: some View {
        List {
            Section {
                if matchingVolumes.isEmpty {
                    StorageVolumeEmptyRow(
                        hasVolumes: !normalizedVolumes.isEmpty,
                        isFiltered: !normalizedSearchText.isEmpty
                    )
                } else {
                    ForEach(matchingVolumes) { volume in
                        if editingState.isEditing {
                            visibilityRow(for: volume)
                        } else {
                            detailsRow(for: volume)
                        }
                    }
                }
            } footer: {
                Text(summaryTitle)
            }

            if editingState.isEditing, hasBulkActions {
                Section(String(localized: "Actions")) {
                    bulkActionRows
                }
            }
        }
        .accessibilityIdentifier("vvterm.stats.storage.volumeList")
    }

    @ViewBuilder
    private func detailsRow(for volume: VolumeInfo) -> some View {
        #if os(iOS)
        detailsButton(for: volume)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                visibilityAction(for: volume)
            }
            .contextMenu {
                visibilityAction(for: volume)
            }
        #else
        detailsButton(for: volume)
            .contextMenu {
                visibilityAction(for: volume)
            }
        #endif
    }

    private func detailsButton(for volume: VolumeInfo) -> some View {
        Button {
            selectedHealthVolume = volume
        } label: {
            HStack(spacing: 8) {
                StorageVolumeSummaryRow(
                    volume: volume,
                    isHidden: isHidden(volume)
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(format: String(localized: "Storage health for %@"), volume.mountPoint)))
        .accessibilityIdentifier(volumeAccessibilityIdentifier(volume, suffix: "health"))
        .accessibilityValue(isHidden(volume) ? Text("Hidden") : Text("Visible"))
    }

    private func visibilityRow(for volume: VolumeInfo) -> some View {
        Toggle(isOn: visibilityBinding(for: volume)) {
            StorageVolumeSummaryRow(
                volume: volume,
                isHidden: isHidden(volume)
            )
            .storageVolumeToggleLabelAlignment()
        }
        .accessibilityIdentifier(volumeAccessibilityIdentifier(volume, suffix: "visibility"))
        .accessibilityValue(isHidden(volume) ? Text("Hidden") : Text("Visible"))
    }

    private func visibilityAction(for volume: VolumeInfo) -> some View {
        let isHidden = isHidden(volume)
        return Button {
            setVolumeVisibility(volume, isHidden)
        } label: {
            Label(
                isHidden ? String(localized: "Show Volume") : String(localized: "Hide Volume"),
                systemImage: isHidden ? "eye" : "eye.slash"
            )
        }
        .tint(isHidden ? .green : .orange)
        .accessibilityIdentifier(volumeAccessibilityIdentifier(volume, suffix: "swipeVisibility"))
    }

    private var toolbarControl: some View {
        Button(editingState.isEditing ? String(localized: "Done") : String(localized: "Edit")) {
            editingState = editingState.isEditing ? .browsing : .editing
        }
        .disabled(normalizedVolumes.isEmpty)
        .accessibilityIdentifier("vvterm.stats.storage.editMode")
    }

    @ViewBuilder
    private var bulkActionRows: some View {
        if hiddenVolumeCount > hiddenContainerVolumes.count {
            Button {
                setVolumesVisibility(normalizedVolumes, true)
            } label: {
                Label(String(localized: "Show All Volumes"), systemImage: "eye")
            }
            .accessibilityIdentifier("vvterm.stats.storage.showAll")
        }

        if !visibleContainerVolumes.isEmpty {
            Button {
                setVolumesVisibility(containerVolumes, false)
            } label: {
                Label(String(localized: "Hide Container Mounts"), systemImage: "eye.slash")
            }
            .accessibilityIdentifier("vvterm.stats.storage.hideContainers")
        }

        if !hiddenContainerVolumes.isEmpty {
            Button {
                setVolumesVisibility(containerVolumes, true)
            } label: {
                Label(String(localized: "Show Container Mounts"), systemImage: "eye")
            }
            .accessibilityIdentifier("vvterm.stats.storage.showContainers")
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingVolumes: [VolumeInfo] {
        StorageVolumeListPolicy.matchingVolumes(
            normalizedVolumes,
            searchText: searchText
        )
    }

    private var normalizedVolumes: [VolumeInfo] {
        VolumeVisibilityPolicy.normalized(volumes)
    }

    private var containerVolumes: [VolumeInfo] {
        let containerVolumeIDs = VolumeVisibilityPolicy.containerVolumeIDs(in: normalizedVolumes)
        return normalizedVolumes.filter { containerVolumeIDs.contains($0.identity) }
    }

    private var visibleContainerVolumes: [VolumeInfo] {
        containerVolumes.filter { !hiddenVolumeIDs.contains($0.identity) }
    }

    private var hiddenContainerVolumes: [VolumeInfo] {
        containerVolumes.filter { hiddenVolumeIDs.contains($0.identity) }
    }

    private var visibleVolumeCount: Int {
        normalizedVolumes.lazy.filter { !hiddenVolumeIDs.contains($0.identity) }.count
    }

    private var hiddenVolumeCount: Int {
        max(0, normalizedVolumes.count - visibleVolumeCount)
    }

    private var hasBulkActions: Bool {
        hiddenVolumeCount > hiddenContainerVolumes.count
            || !visibleContainerVolumes.isEmpty
            || !hiddenContainerVolumes.isEmpty
    }

    private var summaryTitle: String {
        String(
            format: String(localized: "%lld visible, %lld hidden"),
            Int64(visibleVolumeCount),
            Int64(hiddenVolumeCount)
        )
    }

    private func visibilityBinding(for volume: VolumeInfo) -> Binding<Bool> {
        Binding(
            get: { !hiddenVolumeIDs.contains(volume.identity) },
            set: { isVisible in
                setVolumeVisibility(volume, isVisible)
            }
        )
    }

    private func isHidden(_ volume: VolumeInfo) -> Bool {
        hiddenVolumeIDs.contains(volume.identity)
    }
}

private struct StorageVolumeSummaryRow: View {
    let volume: VolumeInfo
    let isHidden: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: volume.kind.systemImage)
                .font(.headline)
                .foregroundStyle(volume.kind.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(volume.mountPoint)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isHidden {
                        Image(systemName: "eye.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Hidden from Stats"))
                    }
                }

                if !metadataTitle.isEmpty {
                    Text(metadataTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                ProgressView(value: min(max(volume.percent / 100, 0), 1))
                    .tint(volume.usageTint)
            }

            Spacer(minLength: 8)

            Text(formatUsedCapacity(volume.used, total: volume.total))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var metadataTitle: String {
        [volume.source, volume.fileSystem]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct StorageVolumeEmptyRow: View {
    let hasVolumes: Bool
    let isFiltered: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle" : "internaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var title: String {
        if isFiltered { return String(localized: "No Matching Volumes") }
        return String(localized: "No Volumes")
    }

    private var message: String {
        if isFiltered, hasVolumes {
            return String(localized: "Clear the search to see all volumes.")
        }
        return String(localized: "No volumes reported")
    }
}

private extension VolumeKind {
    var systemImage: String {
        switch self {
        case .physical:
            return "internaldrive"
        case .container:
            return "shippingbox"
        case .network:
            return "network"
        case .virtual:
            return "externaldrive.badge.questionmark"
        case .unknown:
            return "externaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .physical:
            return .orange
        case .container:
            return .blue
        case .network:
            return .cyan
        case .virtual, .unknown:
            return .secondary
        }
    }
}

private extension VolumeInfo {
    var usageTint: Color {
        if percent > 90 { return .red }
        if percent > 80 { return .orange }
        return .green
    }
}

private func volumeAccessibilityIdentifier(_ volume: VolumeInfo, suffix: String) -> String {
    let identity: String
    switch volume.identity {
    case .stable(let platform, let fileSystemID, let mountPoint):
        identity = "stable|\(platform.rawValue)|\(fileSystemID)|\(mountPoint)"
    case .fallback(let platform, let source, let mountPoint, let fileSystem):
        identity = "fallback|\(platform.rawValue)|\(source)|\(mountPoint)|\(fileSystem)"
    }

    let token = SHA256.hash(data: Data(identity.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return "vvterm.stats.storage.volume.\(token).\(suffix)"
}
