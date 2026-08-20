import SwiftUI

// MARK: - Server Stats View

struct ServerStatsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(StatsResolvedAppearance.storageKey) private var appearanceMode = "system"

    let server: Server
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient? = { nil }

    @ObservedObject private var statsCollector: ServerStatsCollector
    @ObservedObject private var preferencesStore: PreferencesStore
    @ObservedObject private var volumeVisibilityStore: ServerVolumeVisibilityStore
    private let securityApprovalActions: ServerStatsSecurityApprovalActions
    private let isDockerUnlocked: Bool
    @State private var isShowingAppearanceSettings = false
    @State private var isShowingDockerUpgrade = false

    init(
        server: Server,
        backgroundColor: Color,
        sharedClientProvider: @escaping () -> SSHClient? = { nil },
        dependencies: ServerStatsScreenDependencies,
        isDockerUnlocked: Bool
    ) {
        self.server = server
        self.backgroundColor = backgroundColor
        self.sharedClientProvider = sharedClientProvider
        _statsCollector = ObservedObject(
            wrappedValue: dependencies.runtimeStore.collector(for: server.id)
        )
        _preferencesStore = ObservedObject(wrappedValue: dependencies.preferencesStore)
        _volumeVisibilityStore = ObservedObject(wrappedValue: dependencies.volumeVisibilityStore)
        self.securityApprovalActions = dependencies.securityApprovalActions
        self.isDockerUnlocked = isDockerUnlocked
    }

    var body: some View {
        let currentPreferences = preferencesStore.preferences
        let resolvedColorScheme = StatsResolvedAppearance.colorScheme(from: appearanceMode, fallback: colorScheme)

        ServerStatsDashboard(
            server: server,
            backgroundColor: backgroundColor,
            sharedClientProvider: sharedClientProvider,
            statsCollector: statsCollector,
            preferences: currentPreferences,
            volumeVisibilityStore: volumeVisibilityStore,
            securityApprovalActions: securityApprovalActions,
            isDockerUnlocked: isDockerUnlocked
        ) {
            isShowingAppearanceSettings = true
        } showDockerUpgrade: {
            isShowingDockerUpgrade = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            StatsBlocksContent.pageBackground(
                for: currentPreferences.style,
                backgroundColor: backgroundColor,
                colorScheme: resolvedColorScheme
            )
        )
        .proUpgradePresentation(isPresented: $isShowingDockerUpgrade, source: .dockerStats)
        .statsDetailPresentation(isPresented: $isShowingAppearanceSettings, size: StatsPresentationSize.large) {
            StatsAppearanceSettingsSheet(store: preferencesStore)
        }
    }
}
