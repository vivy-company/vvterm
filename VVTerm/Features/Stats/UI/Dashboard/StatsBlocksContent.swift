import SwiftUI

struct StatsAppearancePreviewContent: View {
    let preferences: StatsPreferences

    var body: some View {
        let snapshot = StatsPreviewFixture.presentationSnapshot

        StatsBlocksContent(
            serverName: String(localized: "demo-server"),
            snapshot: snapshot,
            preferences: preferences,
            storageVolumes: VolumeVisibilityPolicy.normalized(snapshot.stats.volumes),
            hiddenStorageVolumeIDs: [],
            backgroundColor: .clear,
            surface: .grouped,
            constrainsWidth: false,
            usesPagePadding: false,
            isDockerUnlocked: true,
            showsCustomizationEntryPoint: false,
            customizeAction: nil,
            dockerUpgradeAction: nil,
            terminateProcess: nil,
            loadProcesses: nil,
            loadDockerStats: nil,
            performDockerAction: nil,
            loadStorageHealth: nil,
            setStorageVolumeVisibility: { _, _ in },
            setStorageVolumesVisibility: { _, _ in }
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

nonisolated enum StatsGridLayoutPolicy {
    static func minimumGridWidth(
        for columnCount: Int,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let safeColumnCount = max(1, columnCount)
        return CGFloat(safeColumnCount) * max(0, minimumColumnWidth)
            + CGFloat(safeColumnCount - 1) * max(0, spacing)
    }

    static func columnCount(
        for availableWidth: CGFloat,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard availableWidth > 0 else { return 1 }
        if availableWidth >= minimumGridWidth(
            for: 3,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        ) {
            return 3
        }
        if availableWidth >= minimumGridWidth(
            for: 2,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        ) {
            return 2
        }
        return 1
    }
}

private struct StatsCardsGridLayout: Layout {
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat
    let preferredColumnSpans: [Int]

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.measurement = nil
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let measurement = measurement(for: proposal.width, subviews: subviews)
        cache.measurement = measurement
        return measurement.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let resolvedMeasurement: Measurement
        if let cachedMeasurement = cache.measurement, cachedMeasurement.size.width == bounds.width {
            resolvedMeasurement = cachedMeasurement
        } else {
            resolvedMeasurement = measurement(for: bounds.width, subviews: subviews)
            cache.measurement = resolvedMeasurement
        }
        var rowOffsets = [CGFloat](repeating: bounds.minY, count: resolvedMeasurement.rowHeights.count)
        for row in rowOffsets.indices.dropFirst() {
            rowOffsets[row] = rowOffsets[row - 1] + resolvedMeasurement.rowHeights[row - 1] + spacing
        }

        for item in resolvedMeasurement.items {
            let width = resolvedMeasurement.width(forColumnSpan: item.columnSpan)
            let x = bounds.minX + CGFloat(item.column) * (resolvedMeasurement.columnWidth + spacing)
            subviews[item.index].place(
                at: CGPoint(x: x, y: rowOffsets[item.row]),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: resolvedMeasurement.rowHeights[item.row])
            )
        }
    }

    private func measurement(for proposedWidth: CGFloat?, subviews: Subviews) -> Measurement {
        let availableWidth = resolvedWidth(proposedWidth)
        let columnCount = StatsGridLayoutPolicy.columnCount(
            for: availableWidth,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        )
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        let columnWidth = max(0, (availableWidth - totalSpacing) / CGFloat(columnCount))
        var items: [Item] = []
        var rowHeights: [CGFloat] = []
        var row = 0
        var column = 0

        for index in subviews.indices {
            let requestedSpan = preferredColumnSpans.indices.contains(index)
                ? preferredColumnSpans[index]
                : 1
            let columnSpan = requestedSpan > 1 && columnCount >= 3 ? 2 : 1

            if column + columnSpan > columnCount {
                row += 1
                column = 0
            }
            if row == rowHeights.count {
                rowHeights.append(0)
            }

            let itemWidth = columnWidth * CGFloat(columnSpan) + spacing * CGFloat(columnSpan - 1)
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            rowHeights[row] = max(rowHeights[row], size.height)
            items.append(Item(index: index, row: row, column: column, columnSpan: columnSpan))

            column += columnSpan
            if column == columnCount {
                row += 1
                column = 0
            }
        }

        let totalHeight = rowHeights.reduce(0, +)
            + CGFloat(max(0, rowHeights.count - 1)) * spacing
        return Measurement(
            size: CGSize(width: availableWidth, height: totalHeight),
            columnWidth: columnWidth,
            items: items,
            rowHeights: rowHeights,
            spacing: spacing
        )
    }

    private func resolvedWidth(_ proposedWidth: CGFloat?) -> CGFloat {
        guard let proposedWidth, proposedWidth.isFinite else {
            return StatsGridLayoutPolicy.minimumGridWidth(
                for: 1,
                minimumColumnWidth: minimumColumnWidth,
                spacing: spacing
            )
        }
        return max(0, proposedWidth)
    }

    struct Item {
        let index: Int
        let row: Int
        let column: Int
        let columnSpan: Int
    }

    struct Cache {
        var measurement: Measurement?
    }

    struct Measurement {
        let size: CGSize
        let columnWidth: CGFloat
        let items: [Item]
        let rowHeights: [CGFloat]
        let spacing: CGFloat

        func width(forColumnSpan span: Int) -> CGFloat {
            columnWidth * CGFloat(span) + spacing * CGFloat(span - 1)
        }
    }
}

struct StatsBlocksContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatsResolvedAppearance.storageKey) private var appearanceMode = "system"

    let serverName: String
    let snapshot: ServerStatsPresentationSnapshot
    let preferences: StatsPreferences
    let storageVolumes: [VolumeInfo]
    let hiddenStorageVolumeIDs: Set<VolumeIdentity>
    let backgroundColor: Color
    let surface: StatsVisualStyle.Surface
    let constrainsWidth: Bool
    let usesPagePadding: Bool
    let isDockerUnlocked: Bool
    let showsCustomizationEntryPoint: Bool
    let customizeAction: (() -> Void)?
    let dockerUpgradeAction: (() -> Void)?
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?
    let loadStorageHealth: ((VolumeInfo) async throws -> StorageHealthResult)?
    let setStorageVolumeVisibility: (VolumeInfo, Bool) -> Void
    let setStorageVolumesVisibility: ([VolumeInfo], Bool) -> Void

    static func pageBackground(
        for preferencesStyle: StatsPreferences.Style,
        backgroundColor: Color,
        colorScheme: ColorScheme = .dark
    ) -> Color {
        if preferencesStyle == .classic {
            return ClassicStatsCardSurfaceStyle.make(for: backgroundColor).pageBackground
        }
        #if os(macOS)
        return colorScheme == .light
            ? StatsVisualStyle(preferencesStyle: preferencesStyle, colorScheme: colorScheme).pageBackground
            : backgroundColor
        #else
        return StatsVisualStyle(preferencesStyle: preferencesStyle, colorScheme: colorScheme).pageBackground
        #endif
    }

    var body: some View {
        let resolvedColorScheme = StatsResolvedAppearance.colorScheme(from: appearanceMode, fallback: colorScheme)
        let style = StatsVisualStyle(
            preferencesStyle: preferences.style,
            surface: surface,
            colorScheme: resolvedColorScheme
        )
        let classicSurfaceStyle = ClassicStatsCardSurfaceStyle.make(for: backgroundColor)

        if preferences.style == .classic {
            ClassicStatsContent(
                serverName: serverName,
                stats: snapshot.stats,
                visibleBlocks: preferences.visibleBlocks,
                surfaceStyle: classicSurfaceStyle,
                isDockerUnlocked: isDockerUnlocked,
                showsCustomizationEntryPoint: showsCustomizationEntryPoint,
                customizeAction: customizeAction,
                dockerUpgradeAction: dockerUpgradeAction,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses,
                loadDockerStats: loadDockerStats,
                performDockerAction: performDockerAction,
                loadStorageHealth: loadStorageHealth,
                storageVolumes: storageVolumes,
                visibleStorageVolumes: visibleStorageVolumes,
                hiddenStorageVolumeIDs: hiddenStorageVolumeIDs,
                setStorageVolumeVisibility: setStorageVolumeVisibility,
                setStorageVolumesVisibility: setStorageVolumesVisibility
            )
            .padding(usesPagePadding ? 16 : 0)
            .drawingGroup()
            .frame(maxWidth: constrainsWidth ? nil : .infinity)
        } else {
            VStack(spacing: style.cardSpacing) {
                responsiveGrid(style: style)

                if showsCustomizationEntryPoint, let customizeAction {
                    StatsCustomizeButton(style: style, action: customizeAction)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, usesPagePadding ? style.horizontalPadding : 0)
            .padding(.top, usesPagePadding ? style.topPadding : 0)
            .padding(.bottom, usesPagePadding ? style.bottomPadding : 0)
            .frame(maxWidth: constrainsWidth ? style.gridMaximumWidth : .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    private var renderedBlocks: [StatsPreferences.BlockID] {
        preferences.visibleBlocks.filter(shouldRenderBlock)
    }

    private func responsiveGrid(style: StatsVisualStyle) -> some View {
        StatsCardsGridLayout(
            minimumColumnWidth: effectiveMinimumColumnWidth(for: style),
            spacing: style.cardSpacing,
            preferredColumnSpans: renderedBlocks.map { blockID in
                blockID == .docker && isDockerUnlocked ? 2 : 1
            }
        ) {
            ForEach(renderedBlocks, id: \.self) { blockID in
                statsBlock(blockID, style: style)
                    .accessibilityIdentifier("vvterm.stats.card.\(blockID.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func effectiveMinimumColumnWidth(for style: StatsVisualStyle) -> CGFloat {
        guard renderedBlocks.contains(.docker), !isDockerUnlocked, dockerUpgradeAction != nil else {
            return style.gridMinimumColumnWidth
        }
        return max(style.gridMinimumColumnWidth, LockedDockerCard.wideLayoutMinimumWidth)
    }

    private func shouldRenderBlock(_ blockID: StatsPreferences.BlockID) -> Bool {
        switch blockID {
        case .gpu:
            return shouldShowGPU
        case .docker:
            return isDockerUnlocked || dockerUpgradeAction != nil
        case .system, .cpu, .memory, .network, .storage, .processes:
            return true
        }
    }

    @ViewBuilder
    private func statsBlock(_ blockID: StatsPreferences.BlockID, style: StatsVisualStyle) -> some View {
        switch blockID {
        case .system:
            SystemOverviewCard(
                serverName: serverName,
                stats: snapshot.stats,
                style: style
            )
        case .cpu:
            CPUCard(
                stats: snapshot.stats,
                history: snapshot.cpuHistory,
                style: style
            )
        case .memory:
            MemoryCard(
                stats: snapshot.stats,
                history: snapshot.memoryHistory,
                style: style
            )
        case .gpu:
            if shouldShowGPU {
                GPUCard(
                    stats: snapshot.stats,
                    histories: snapshot.gpuHistories,
                    style: style
                )
            }
        case .network:
            NetworkCard(
                stats: snapshot.stats,
                rxHistory: snapshot.networkRxHistory,
                txHistory: snapshot.networkTxHistory,
                style: style
            )
        case .storage:
            StorageCard(
                volumes: storageVolumes,
                visibleVolumes: visibleStorageVolumes,
                hiddenVolumeIDs: hiddenStorageVolumeIDs,
                style: style,
                loadStorageHealth: loadStorageHealth,
                setVolumeVisibility: setStorageVolumeVisibility,
                setVolumesVisibility: setStorageVolumesVisibility
            )
        case .processes:
            ProcessesCard(
                processes: snapshot.stats.topProcesses,
                processCount: snapshot.stats.processCount,
                style: style,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
        case .docker:
            if isDockerUnlocked {
                DockerCard(
                    docker: snapshot.stats.docker,
                    cpuHistory: snapshot.dockerCPUHistory,
                    memoryHistory: snapshot.dockerMemoryHistory,
                    style: style,
                    loadDockerStats: loadDockerStats,
                    performDockerAction: performDockerAction
                )
            } else if let dockerUpgradeAction {
                LockedDockerCard(style: style, action: dockerUpgradeAction)
            }
        }
    }

    private var shouldShowGPU: Bool {
        !snapshot.stats.hardware.gpus.isEmpty || !snapshot.stats.gpuSamples.isEmpty
    }

    private var visibleStorageVolumes: [VolumeInfo] {
        StorageVolumePresentationPolicy.visibleVolumes(
            from: storageVolumes,
            hiddenVolumeIDs: hiddenStorageVolumeIDs
        )
    }
}
