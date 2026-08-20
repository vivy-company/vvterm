#if os(iOS) && DEBUG
import SwiftUI

struct StatsCardsLayoutUITestHarness: View {
    private let style: StatsPreferences.Style
    private let isDockerUnlocked: Bool

    init(arguments: [String] = Foundation.ProcessInfo.processInfo.arguments) {
        if arguments.contains("--vvterm-ui-test-stats-cards-classic") {
            style = .classic
        } else if arguments.contains("--vvterm-ui-test-stats-cards-compact") {
            style = .cardsCompact
        } else {
            style = .cardsDetailed
        }
        isDockerUnlocked = !arguments.contains("--vvterm-ui-test-stats-cards-locked-docker")
    }

    var body: some View {
        let snapshot = StatsPreviewFixture.presentationSnapshot

        ScrollView {
            StatsBlocksContent(
                serverName: "layout-test",
                snapshot: snapshot,
                preferences: preferences,
                storageVolumes: VolumeVisibilityPolicy.normalized(snapshot.stats.volumes),
                hiddenStorageVolumeIDs: [],
                backgroundColor: .black,
                surface: .dashboard,
                constrainsWidth: true,
                usesPagePadding: true,
                isDockerUnlocked: isDockerUnlocked,
                showsCustomizationEntryPoint: true,
                customizeAction: {},
                dockerUpgradeAction: isDockerUnlocked ? nil : {},
                terminateProcess: nil,
                loadProcesses: nil,
                loadDockerStats: nil,
                performDockerAction: nil,
                loadStorageHealth: nil,
                setStorageVolumeVisibility: { _, _ in },
                setStorageVolumesVisibility: { _, _ in }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vvterm.stats.layout.container")
        .background(StatsBlocksContent.pageBackground(for: style, backgroundColor: .black))
    }

    private var preferences: StatsPreferences {
        var preferences = StatsPreferences.defaultValue(lastWriterDeviceId: "ui-test")
        preferences.style = style
        return preferences
    }
}
#endif
