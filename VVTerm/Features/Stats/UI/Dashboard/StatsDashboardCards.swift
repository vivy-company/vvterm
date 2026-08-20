import SwiftUI

// MARK: - Summary

struct SystemOverviewCard: View {
    let serverName: String
    let stats: ServerStats
    let style: StatsVisualStyle
    @State private var showingDetails = false

    var body: some View {
        AppleCard(style: style, minHeight: style.overviewMinHeight) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.headline.weight(.bold))
                            Text(displayName)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(Color.cyan)

                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    Button {
                        showingDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(style.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("System Details"))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(formatUptimeDetail(stats.uptime))
                        .font(.system(size: style.prominentValueSize, weight: .bold, design: .rounded))
                        .foregroundStyle(style.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Text(String(localized: "Uptime"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(style.secondaryText)
                }

                HStack(spacing: 18) {
                    FooterValue(
                        title: String(localized: "Load"),
                        value: String(format: "%.2f", stats.loadAverage.0),
                        color: .orange,
                        style: style
                    )

                    FooterValue(
                        title: String(localized: "Processes"),
                        value: stats.processCount > 0 ? "\(stats.processCount)" : "-",
                        color: .purple,
                        style: style
                    )
                }
            }
            .padding(style.cardPadding)
        }
        .statsDetailPresentation(isPresented: $showingDetails) {
            SystemDetailsSheet(stats: stats)
        }
    }

    private var displayName: String {
        serverName.isEmpty ? String(localized: "System") : serverName
    }

    private var subtitle: String {
        if !stats.hostname.isEmpty, !stats.osInfo.isEmpty, stats.hostname != serverName {
            return "\(stats.hostname)\n\(stats.osInfo)"
        }
        if !stats.osInfo.isEmpty {
            return stats.osInfo
        }
        if !stats.hostname.isEmpty, stats.hostname != serverName {
            return stats.hostname
        }
        return ""
    }
}

// MARK: - Metric Cards

struct CPUCard: View {
    let stats: ServerStats
    let history: [StatsPoint]
    let style: StatsVisualStyle
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleMetricCard(
                icon: "cpu",
                title: String(localized: "CPU"),
                titleColor: .pink,
                trailing: cpuCountTitle,
                value: formatPercent(stats.cpuUsage),
                unit: "",
                footer: footer,
                detailItems: [
                    MetricDetailItem(title: String(localized: "User"), value: formatPercent(stats.cpuUser), color: .pink),
                    MetricDetailItem(title: String(localized: "System"), value: formatPercent(stats.cpuSystem), color: .orange),
                    MetricDetailItem(title: String(localized: "I/O Wait"), value: formatPercent(stats.cpuIowait), color: .yellow),
                    MetricDetailItem(title: String(localized: "Idle"), value: formatPercent(stats.cpuIdle), color: .green)
                ],
                showsChevron: true,
                style: style
            ) {
                MetricPreviewChart(
                    history: history,
                    color: .pink,
                    yDomain: 0...100,
                    style: style
                )
            }
        }
        .buttonStyle(.plain)
        .statsDetailPresentation(isPresented: $showingDetails) {
            CPUDetailsSheet(stats: stats)
        }
    }

    private var cpuCountTitle: String {
        let count = max(stats.cpuCoreSamples.count, stats.cpuCores)
        if count <= 0 { return "" }
        if count == 1 { return String(localized: "1 core") }
        return String(format: String(localized: "%lld cores"), Int64(count))
    }

    private var footer: String {
        style.density == .detailed ? "" : compactFooter
    }

    private var compactFooter: String {
        String(
            format: String(localized: "User %@  System %@  Idle %@"),
            formatPercent(stats.cpuUser),
            formatPercent(stats.cpuSystem),
            formatPercent(stats.cpuIdle)
        )
    }
}

struct MemoryCard: View {
    let stats: ServerStats
    let history: [StatsPoint]
    let style: StatsVisualStyle

    var body: some View {
        AppleMetricCard(
            icon: "memorychip",
            title: String(localized: "Memory"),
            titleColor: .blue,
            trailing: String(localized: "Today"),
            value: formatPercent(stats.memoryPercent),
            unit: "",
            footer: formatUsedCapacity(stats.memoryUsed, total: stats.memoryTotal),
            detailItems: [
                MetricDetailItem(title: String(localized: "Used"), value: formatBytes(stats.memoryUsed), color: .blue),
                MetricDetailItem(title: String(localized: "Free"), value: formatBytes(stats.memoryFree), color: .green),
                MetricDetailItem(title: String(localized: "Cached"), value: formatBytes(stats.memoryCached), color: .cyan),
                MetricDetailItem(title: String(localized: "Buffers"), value: formatBytes(stats.memoryBuffers), color: .orange)
            ],
            style: style
        ) {
            MetricPreviewChart(
                history: history,
                color: .blue,
                yDomain: 0...100,
                style: style
            )
        }
    }
}

struct GPUCard: View {
    let stats: ServerStats
    let histories: [String: [StatsPoint]]
    let style: StatsVisualStyle
    @State private var showingDetails = false

    private var devices: [GPUDevice] {
        if !stats.hardware.gpus.isEmpty {
            return stats.hardware.gpus
        }
        return stats.gpuSamples.map { sample in
            GPUDevice(
                id: sample.deviceID,
                name: sample.deviceID,
                vendor: "",
                kind: .unknown,
                driverVersion: "",
                memoryTotal: sample.memoryTotal ?? 0,
                source: sample.source
            )
        }
    }

    private var primaryDevice: GPUDevice? {
        if let primarySample {
            return devices.first { $0.id == primarySample.deviceID }
        }
        return devices.first
    }

    private var primarySample: GPUSample? {
        stats.gpuSamples.max { lhs, rhs in
            (lhs.utilizationPercent ?? -1) < (rhs.utilizationPercent ?? -1)
        }
    }

    private var primaryHistory: [StatsPoint] {
        guard let sample = primarySample else { return [] }
        return histories[sample.deviceID] ?? []
    }

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleCard(style: style, minHeight: style.metricMinHeight) {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader(
                        icon: StatsIcon.gpu,
                        title: String(localized: "GPU"),
                        titleColor: .green,
                        trailing: deviceCountTitle,
                        showsChevron: true,
                        style: style
                    )

                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Utilization"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(style.secondaryText)

                            Text(utilizationLabel(primarySample))
                                .font(.system(size: style.metricValueSize, weight: .bold, design: .rounded))
                                .foregroundStyle(style.primaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            Text(footerLabel(device: primaryDevice, sample: primarySample))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }

                        Spacer(minLength: 8)

                        MetricPreviewChart(
                            history: primaryHistory,
                            color: .green,
                            yDomain: 0...100,
                            style: style
                        )
                        .frame(width: style.metricPreviewWidth, height: style.metricPreviewHeight)
                    }

                    if style.density == .detailed {
                        VStack(spacing: 12) {
                            ForEach(devices.prefix(3)) { device in
                                GPUDeviceRow(
                                    device: device,
                                    sample: stats.gpuSamples.first { $0.deviceID == device.id },
                                    style: style
                                )
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .statsDetailPresentation(isPresented: $showingDetails) {
            GPUDetailsSheet(stats: stats, devices: devices)
        }
    }

    private var deviceCountTitle: String {
        if devices.isEmpty {
            return ""
        }
        if devices.count == 1 {
            return String(localized: "1 device")
        }
        return String(format: String(localized: "%lld devices"), Int64(devices.count))
    }

    private func utilizationLabel(_ sample: GPUSample?) -> String {
        guard let utilization = sample?.utilizationPercent else {
            return String(localized: "No Data")
        }
        return formatPercent(utilization)
    }

    private func footerLabel(device: GPUDevice?, sample: GPUSample?) -> String {
        if let vram = aggregateVRAMUsage {
            return formatUsedCapacity(vram.used, total: vram.total)
        }
        let memoryTotal = sample?.memoryTotal ?? device?.memoryTotal ?? 0
        if let memoryUsed = sample?.memoryUsed, memoryTotal > 0 {
            return formatUsedCapacity(memoryUsed, total: memoryTotal)
        }
        if let temperature = sample?.temperatureCelsius {
            return String(format: String(localized: "%.0f C"), temperature)
        }
        if let device, !device.displayName.isEmpty {
            return device.displayName
        }
        return String(localized: "Waiting for telemetry")
    }

    private var aggregateVRAMUsage: (used: UInt64, total: UInt64)? {
        var devicesByID: [String: GPUDevice] = [:]
        for device in devices {
            devicesByID[device.id] = device
        }

        var sampledDeviceIDs = Set<String>()
        var used: UInt64 = 0
        var total: UInt64 = 0
        var hasUsedSample = false

        for sample in stats.gpuSamples {
            sampledDeviceIDs.insert(sample.deviceID)
            if let memoryUsed = sample.memoryUsed {
                used += memoryUsed
                hasUsedSample = true
            }
            total += sample.memoryTotal ?? devicesByID[sample.deviceID]?.memoryTotal ?? 0
        }

        for device in devices where !sampledDeviceIDs.contains(device.id) {
            total += device.memoryTotal
        }

        guard hasUsedSample, total > 0 else { return nil }
        return (used, total)
    }
}

private struct GPUDeviceRow: View {
    let device: GPUDevice
    let sample: GPUSample?
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            ProcessBadge(
                title: String(localized: "GPU"),
                value: sample?.utilizationPercent ?? 0,
                color: .green,
                style: style
            )
        }
    }

    private var detail: String {
        if let power = sample?.powerWatts, let temp = sample?.temperatureCelsius {
            return String(format: String(localized: "%.0f W  %.0f C"), power, temp)
        }
        if let memoryUsed = sample?.memoryUsed {
            let memoryTotal = sample?.memoryTotal ?? device.memoryTotal
            if memoryTotal > 0 {
                return formatUsedCapacity(memoryUsed, total: memoryTotal)
            }
            return String(format: String(localized: "%@ VRAM used"), formatBytes(memoryUsed))
        }
        if device.memoryTotal > 0 {
            return String(format: String(localized: "%@ VRAM"), formatBytes(device.memoryTotal))
        }
        return device.vendor.isEmpty ? String(localized: "GPU") : device.vendor
    }
}

struct NetworkCard: View {
    let stats: ServerStats
    let rxHistory: [StatsPoint]
    let txHistory: [StatsPoint]
    let style: StatsVisualStyle

    var body: some View {
        AppleCard(style: style, minHeight: style.networkMinHeight) {
            VStack(alignment: .leading, spacing: 18) {
                CardHeader(
                    icon: "arrow.up.arrow.down",
                    title: String(localized: "Network"),
                    titleColor: .cyan,
                    trailing: String(localized: "Live"),
                    style: style
                )

                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        NetworkValue(
                            symbol: "arrow.down",
                            title: String(localized: "Download"),
                            value: formatSpeed(stats.networkRxSpeed),
                            color: .cyan,
                            style: style
                        )

                        NetworkValue(
                            symbol: "arrow.up",
                            title: String(localized: "Upload"),
                            value: formatSpeed(stats.networkTxSpeed),
                            color: .orange,
                            style: style
                        )
                    }
                    .frame(width: style.networkValuesWidth, alignment: .leading)

                    NetworkLineChart(
                        rxHistory: rxHistory,
                        txHistory: txHistory,
                        style: style
                    )
                    .frame(maxWidth: .infinity, minHeight: style.networkChartHeight, maxHeight: style.networkChartHeight)
                }

                HStack(spacing: 18) {
                    FooterValue(
                        title: String(localized: "Received"),
                        value: formatBytes(stats.networkRxTotal),
                        color: .cyan,
                        style: style
                    )
                    FooterValue(
                        title: String(localized: "Sent"),
                        value: formatBytes(stats.networkTxTotal),
                        color: .orange,
                        style: style
                    )
                }
            }
            .padding(style.cardPadding)
        }
    }
}

// MARK: - Detail Cards

struct StorageCard: View {
    let volumes: [VolumeInfo]
    let visibleVolumes: [VolumeInfo]
    let hiddenVolumeIDs: Set<VolumeIdentity>
    let style: StatsVisualStyle
    let loadStorageHealth: ((VolumeInfo) async throws -> StorageHealthResult)?
    let setVolumeVisibility: (VolumeInfo, Bool) -> Void
    let setVolumesVisibility: ([VolumeInfo], Bool) -> Void
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleCard(style: style) {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader(
                        icon: "internaldrive",
                        title: String(localized: "Storage"),
                        titleColor: .orange,
                        trailing: volumeCountTitle,
                        showsChevron: true,
                        style: style
                    )

                    if visibleVolumes.isEmpty {
                        EmptyCardState(
                            icon: volumes.isEmpty ? "internaldrive" : "eye.slash",
                            title: volumes.isEmpty ? String(localized: "No Data") : String(localized: "All Hidden"),
                            message: volumes.isEmpty ? String(localized: "No volumes reported") : String(localized: "Open Storage to restore volumes"),
                            color: .orange,
                            style: style
                        )
                    } else {
                        VStack(spacing: 14) {
                            ForEach(StorageVolumePresentationPolicy.cardVolumes(
                                from: visibleVolumes,
                                limit: style.volumeLimit
                            )) { volume in
                                VolumeCardRow(volume: volume, style: style)
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vvterm.stats.storage.card")
        .statsDetailPresentation(isPresented: $showingDetails, size: StatsPresentationSize.large) {
            StorageDetailsSheet(
                volumes: volumes,
                hiddenVolumeIDs: hiddenVolumeIDs,
                loadStorageHealth: loadStorageHealth,
                setVolumeVisibility: setVolumeVisibility,
                setVolumesVisibility: setVolumesVisibility
            )
        }
    }

    private var volumeCountTitle: String {
        if volumes.isEmpty { return "" }
        if visibleVolumes.count == 1 { return String(localized: "1 volume") }
        return String(format: String(localized: "%lld volumes"), Int64(visibleVolumes.count))
    }
}

struct ProcessesCard: View {
    let processes: [ProcessInfo]
    let processCount: Int
    let style: StatsVisualStyle
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?
    @State private var showingProcesses = false

    var body: some View {
        Button {
            if !processes.isEmpty {
                showingProcesses = true
            }
        } label: {
            AppleCard(style: style) {
                VStack(alignment: .leading, spacing: 18) {
                    ProcessCardHeader(
                        processCount: processCount,
                        style: style,
                        showsChevron: !processes.isEmpty
                    )

                    if processes.isEmpty {
                        EmptyCardState(
                            icon: "list.bullet.rectangle",
                            title: String(localized: "No Data"),
                            message: String(localized: "No processes reported"),
                            color: .purple,
                            style: style
                        )
                    } else {
                        VStack(spacing: 16) {
                            ForEach(processes.prefix(style.processLimit)) { process in
                                ProcessCardRow(process: process, style: style)
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .statsDetailPresentation(isPresented: $showingProcesses, size: StatsPresentationSize.large) {
            ProcessesSheet(
                processes: processes,
                processCount: processCount,
                terminateProcess: terminateProcess,
                loadProcesses: loadProcesses
            )
        }
    }
}

struct DockerCard: View {
    let docker: DockerStats
    let cpuHistory: [StatsPoint]
    let memoryHistory: [StatsPoint]
    let style: StatsVisualStyle
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            AppleCard(style: style, minHeight: style.metricMinHeight) {
                VStack(alignment: .leading, spacing: 18) {
                    CardHeader(
                        icon: "shippingbox",
                        title: String(localized: "Docker"),
                        titleColor: .blue,
                        trailing: trailing,
                        showsChevron: true,
                        style: style
                    )

                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metricLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(style.secondaryText)

                            Text(metricValue)
                                .font(.system(size: style.metricValueSize, weight: .bold, design: .rounded))
                                .foregroundStyle(style.primaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            Text(footer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                        }

                        Spacer(minLength: 8)

                        MetricPreviewChart(
                            history: chartHistory,
                            color: .blue,
                            yDomain: chartYDomain,
                            style: style
                        )
                        .frame(width: style.metricPreviewWidth, height: style.metricPreviewHeight)
                    }

                    if style.density == .detailed {
                        MetricDetailGrid(items: detailItems, style: style)

                        if docker.isAvailable, !docker.topContainers.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(docker.topContainers.prefix(3)) { container in
                                    DockerContainerCardRow(container: container, style: style)
                                }
                            }
                        }
                    }
                }
                .padding(style.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .statsDetailPresentation(isPresented: $showingDetails, size: StatsPresentationSize.large) {
            DockerDetailsSheet(
                docker: docker,
                loadDockerStats: loadDockerStats,
                performDockerAction: performDockerAction
            )
        }
    }

    private var trailing: String {
        guard docker.isAvailable else { return String(localized: "Unavailable") }
        if docker.runningCount == 1 { return String(localized: "1 running") }
        return String(format: String(localized: "%lld running"), Int64(docker.runningCount))
    }

    private var metricLabel: String {
        docker.isAvailable ? String(localized: "Running") : String(localized: "Status")
    }

    private var metricValue: String {
        guard docker.isAvailable else { return String(localized: "No Data") }
        return "\(docker.runningCount)"
    }

    private var footer: String {
        guard docker.isAvailable else { return docker.availability.message }
        if docker.totalCount == 0 {
            return String(localized: "No containers reported")
        }
        return String(
            format: String(localized: "%lld containers reported"),
            Int64(docker.totalCount)
        )
    }

    private var chartHistory: [StatsPoint] {
        docker.isAvailable ? cpuHistory : memoryHistory
    }

    private var chartYDomain: ClosedRange<Double> {
        guard docker.isAvailable else { return 0...100 }
        let highestValue = chartHistory.reduce(docker.aggregateCPUPercent) { partialResult, point in
            max(partialResult, point.value)
        }
        let upperBound = max(100, (highestValue / 100).rounded(.up) * 100)
        return 0...upperBound
    }

    private var detailItems: [MetricDetailItem] {
        [
            MetricDetailItem(title: String(localized: "CPU"), value: formatPercent(docker.aggregateCPUPercent), color: .pink),
            MetricDetailItem(title: String(localized: "Memory"), value: formatPercent(docker.memoryPercent), color: .blue),
            MetricDetailItem(title: String(localized: "Stopped"), value: "\(docker.stoppedCount)", color: .secondary),
            MetricDetailItem(title: String(localized: "Unhealthy"), value: "\(docker.unhealthyCount)", color: .red)
        ]
    }
}

struct LockedDockerCard: View {
    static let wideLayoutMinimumWidth: CGFloat = 560

    let style: StatsVisualStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppleCard(style: style) {
                ViewThatFits(in: .horizontal) {
                    wideLayout
                        .frame(minWidth: Self.wideLayoutMinimumWidth, alignment: .topLeading)
                    compactLayout
                }
                .padding(style.cardPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .buttonStyle(StatsCardButtonStyle())
        .accessibilityLabel(Text("Unlock Docker monitoring"))
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                header

                Text(String(localized: "Inspect containers, catch unhealthy services, and control Docker without leaving your session."))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                unlockPill
            }
            .frame(maxWidth: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: 13) {
                featureRows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                header
                Spacer(minLength: 8)
                compactUnlockPill
            }

            Text(String(localized: "Inspect containers, catch unhealthy services, and control Docker."))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                featureRows
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .frame(width: 46, height: 46)
                    .background(Color.blue.opacity(0.14), in: Circle())

                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Color.blue, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(style.cardFill, lineWidth: 2)
                    }
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(localized: "Docker"))
                        .font(.headline.weight(.bold))
                    ProBadge(compact: true)
                }
                .foregroundStyle(style.primaryText)

                Text(String(localized: "Pro monitoring"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var unlockPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.open")
                .font(.caption.weight(.bold))
            Text(String(localized: "Unlock Docker"))
                .font(.subheadline.weight(.bold))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.blue)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.12), in: Capsule())
    }

    private var compactUnlockPill: some View {
        ViewThatFits(in: .horizontal) {
            unlockPill
            HStack(spacing: 6) {
                Image(systemName: "lock.open")
                    .font(.caption.weight(.bold))
                Text(String(localized: "Unlock"))
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Color.blue)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private var featureRows: some View {
        LockedDockerFeature(
            systemImage: "list.bullet.rectangle",
            title: String(localized: "Containers"),
            subtitle: String(localized: "Search, sort, and inspect state"),
            color: .blue,
            style: style
        )
        LockedDockerFeature(
            systemImage: "waveform.path.ecg",
            title: String(localized: "Health"),
            subtitle: String(localized: "Spot unhealthy services fast"),
            color: .green,
            style: style
        )
        LockedDockerFeature(
            systemImage: "power",
            title: String(localized: "Actions"),
            subtitle: String(localized: "Start, stop, and restart"),
            color: .orange,
            style: style
        )
    }
}

private struct LockedDockerFeature: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let color: Color
    let style: StatsVisualStyle

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

private struct DockerContainerCardRow: View {
    let container: DockerContainer
    let style: StatsVisualStyle

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(dockerStatusColor(container))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(container.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(container.image)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ProcessBadge(
                title: String(localized: "CPU"),
                value: container.cpuPercent,
                color: .pink,
                style: style
            )

            ProcessBadge(
                title: String(localized: "MEM"),
                value: container.memoryPercent,
                color: .blue,
                style: style
            )
        }
    }
}
