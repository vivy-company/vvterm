#if os(iOS) && DEBUG
import SwiftUI

struct StatsStorageUITestHarness: View {
    @State private var hiddenVolumeIDs: Set<VolumeIdentity>

    private static let volumes = [
        VolumeInfo(
            platform: .linux,
            mountPoint: "/",
            source: "/dev/nvme0n1p2",
            fileSystem: "ext4",
            stableIdentifier: "root-uuid",
            used: 420_000_000_000,
            total: 1_000_000_000_000
        ),
        VolumeInfo(
            platform: .linux,
            mountPoint: "/mnt/share",
            source: "nas:/share",
            fileSystem: "nfs4",
            stableIdentifier: "share-uuid",
            used: 200_000_000_000,
            total: 2_000_000_000_000
        ),
        VolumeInfo(
            platform: .linux,
            mountPoint: "/mnt/mirror",
            source: "/dev/sda1",
            fileSystem: "btrfs",
            stableIdentifier: "mirror-uuid",
            used: 300_000_000_000,
            total: 1_000_000_000_000
        ),
        VolumeInfo(
            platform: .linux,
            mountPoint: "/var/lib/docker/overlay2/example/merged",
            source: "overlay",
            fileSystem: "overlay",
            used: 20_000_000_000,
            total: 100_000_000_000
        )
    ]

    init() {
        _hiddenVolumeIDs = State(initialValue: [Self.volumes[3].identity])
    }

    var body: some View {
        StorageDetailsSheet(
            volumes: Self.volumes,
            hiddenVolumeIDs: hiddenVolumeIDs,
            loadStorageHealth: loadHealth,
            setVolumeVisibility: setVolumeVisibility,
            setVolumesVisibility: setVolumesVisibility
        )
    }

    private func loadHealth(for volume: VolumeInfo) async throws -> StorageHealthResult {
        try await Task.sleep(for: .milliseconds(80))
        switch volume.kind {
        case .network:
            return .unavailable(.networkVolume)
        case .container, .virtual:
            return .unavailable(.virtualDevice)
        case .physical, .unknown:
            if volume.fileSystem.lowercased() == "btrfs" {
                return mirrorHealthFixture()
            }
            var metrics = StorageHealthMetrics()
            metrics.temperatureCelsius = 37
            metrics.percentageUsed = 8
            metrics.availableSparePercent = 100
            metrics.powerOnHours = 1_024
            let deviceID = StorageDeviceIdentity(namespace: "ui-test", opaqueValue: "fixture")
            let device = StorageHealthReport(
                deviceID: deviceID,
                state: .healthy,
                metrics: metrics,
                sources: [.smartctl],
                findings: [StorageHealthFinding(
                    kind: .smartCurrentPrefailThreshold,
                    severity: .warning,
                    source: .smartctl
                )]
            )
            return .report(StorageHealthVolumeReport(
                topology: .physicalDevice,
                name: nil,
                coverage: .complete,
                findings: [],
                members: [StorageHealthMemberReport(
                    id: deviceID,
                    role: .data,
                    ordinal: 1,
                    result: .report(device)
                )]
            ))
        }
    }

    private func mirrorHealthFixture() -> StorageHealthResult {
        let firstID = StorageDeviceIdentity(namespace: "ui-test", opaqueValue: "mirror-1")
        let secondID = StorageDeviceIdentity(namespace: "ui-test", opaqueValue: "mirror-2")
        return .report(StorageHealthVolumeReport(
            topology: .btrfs,
            name: "data",
            coverage: .partial,
            findings: [StorageHealthFinding(
                kind: .partialCoverage,
                severity: .information,
                source: .btrfs
            )],
            members: [
                StorageHealthMemberReport(
                    id: firstID,
                    role: .data,
                    ordinal: 1,
                    result: .report(StorageHealthReport(
                        deviceID: firstID,
                        state: .healthy,
                        sources: [.smartctl]
                    ))
                ),
                StorageHealthMemberReport(
                    id: secondID,
                    role: .data,
                    ordinal: 2,
                    result: .unavailable(.permissionDenied)
                )
            ]
        ))
    }

    private func setVolumeVisibility(_ volume: VolumeInfo, _ isVisible: Bool) {
        if isVisible {
            hiddenVolumeIDs.remove(volume.identity)
        } else {
            hiddenVolumeIDs.insert(volume.identity)
        }
    }

    private func setVolumesVisibility(_ volumes: [VolumeInfo], _ areVisible: Bool) {
        for volume in volumes {
            setVolumeVisibility(volume, areVisible)
        }
    }

}
#endif
