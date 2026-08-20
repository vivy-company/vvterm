import SwiftUI

struct ServerStatsDashboard: View {
    let server: Server
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient?
    @ObservedObject var statsCollector: ServerStatsCollector
    let preferences: StatsPreferences
    @ObservedObject var volumeVisibilityStore: ServerVolumeVisibilityStore
    let securityApprovalActions: ServerStatsSecurityApprovalActions
    let isDockerUnlocked: Bool
    let showAppearanceSettings: () -> Void
    let showDockerUpgrade: () -> Void
    @State private var approvalRequestInFlight: ServerSecurityApprovalRequest?

    var body: some View {
        let style = StatsVisualStyle(preferencesStyle: preferences.style)
        let snapshot = statsCollector.presentationSnapshot
        let storageVolumes = VolumeVisibilityPolicy.normalized(snapshot.stats.volumes)
        let hiddenStorageVolumeIDs = volumeVisibilityStore.hiddenVolumeIDs(
            for: server.id,
            volumes: storageVolumes
        )

        ZStack {
            ScrollView {
                StatsBlocksContent(
                    serverName: server.name,
                    snapshot: snapshot,
                    preferences: preferences,
                    storageVolumes: storageVolumes,
                    hiddenStorageVolumeIDs: hiddenStorageVolumeIDs,
                    backgroundColor: backgroundColor,
                    surface: .dashboard,
                    constrainsWidth: true,
                    usesPagePadding: true,
                    isDockerUnlocked: isDockerUnlocked,
                    showsCustomizationEntryPoint: true,
                    customizeAction: showAppearanceSettings,
                    dockerUpgradeAction: showDockerUpgrade,
                    terminateProcess: { process in
                        try await statsCollector.terminateProcess(process)
                    },
                    loadProcesses: {
                        try await statsCollector.loadProcesses()
                    },
                    loadDockerStats: {
                        try await statsCollector.loadDockerStats()
                    },
                    performDockerAction: { action, container in
                        try await statsCollector.performDockerAction(action, on: container)
                    },
                    loadStorageHealth: { volume in
                        try await statsCollector.loadStorageHealth(for: volume)
                    },
                    setStorageVolumeVisibility: { volume, isVisible in
                        volumeVisibilityStore.setVolume(volume, isVisible: isVisible, for: server.id)
                    },
                    setStorageVolumesVisibility: { volumes, areVisible in
                        volumeVisibilityStore.setVolumes(volumes, areVisible: areVisible, for: server.id)
                    }
                )
            }

            if let error = statsCollector.connectionError {
                ConnectionErrorOverlay(error: error, style: style) {
                    Task {
                        await statsCollector.startCollecting(
                            for: server,
                            using: sharedClientProvider(),
                            collectDocker: isDockerUnlocked
                        )
                    }
                }
                .padding()
            }
        }
        .task(id: makeTaskKey()) {
            await statsCollector.startCollecting(
                for: server,
                using: sharedClientProvider(),
                collectDocker: isDockerUnlocked
            )
        }
        .task(id: approvalRequestInFlight?.id) {
            await performSecurityApprovalIfNeeded()
        }
        .onDisappear {
            approvalRequestInFlight = nil
            statsCollector.pauseCollecting()
        }
        .sshHostKeyTrustAlert(
            request: hostKeyRequest,
            isPresented: hostKeyApprovalBinding,
            onCancel: { _ in cancelHostKeyApproval() },
            onApprove: { _ in beginHostKeyApproval() }
        )
    }

    private var hostKeyRequest: ServerSecurityApprovalRequest? {
        guard let request = statsCollector.securityApproval,
              case .hostKey = request else {
            return nil
        }
        return request
    }

    private var hostKeyApprovalBinding: Binding<Bool> {
        Binding(
            get: { hostKeyRequest != nil },
            set: { _ in }
        )
    }

    private func cancelHostKeyApproval() {
        guard let request = statsCollector.securityApproval,
              case .hostKey = request else { return }
        approvalRequestInFlight = nil
        securityApprovalActions.reject(request)
        statsCollector.resolveSecurityApproval(request, error: .cancelled)
    }

    private func beginHostKeyApproval() {
        guard let request = statsCollector.securityApproval,
              case .hostKey = request else { return }
        approvalRequestInFlight = request
    }

    private func performSecurityApprovalIfNeeded() async {
        guard let request = approvalRequestInFlight else { return }
        let outcome = await securityApprovalActions.approve(request)

        guard !Task.isCancelled else { return }
        guard approvalRequestInFlight == request,
              statsCollector.securityApproval == request else {
            if approvalRequestInFlight == request {
                approvalRequestInFlight = nil
            }
            return
        }

        switch outcome {
        case .approved:
            statsCollector.resolveSecurityApproval(request)
            await retryCollection()
            guard !Task.isCancelled, approvalRequestInFlight == request else { return }
        case .failed(let error):
            statsCollector.resolveSecurityApproval(request, error: error)
        }
        approvalRequestInFlight = nil
    }

    private func retryCollection() async {
        await statsCollector.startCollecting(
            for: server,
            using: sharedClientProvider(),
            collectDocker: isDockerUnlocked
        )
    }

    private func makeTaskKey() -> String {
        let clientId = sharedClientProvider().map { ObjectIdentifier($0).hashValue } ?? 0
        return "\(server.id.uuidString)-\(clientId)-\(isDockerUnlocked)"
    }
}
