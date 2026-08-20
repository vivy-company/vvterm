import Combine
import Foundation

@MainActor
private final class CloudKitSyncSettingsAdapter: SyncSettingsCloudSyncing {
    private let cloudKit: CloudKitManager
    private let pendingSync: CloudKitSyncCoordinator
    private let statusStore: CloudKitSyncStatusStore

    init(
        cloudKit: CloudKitManager,
        pendingSync: CloudKitSyncCoordinator
    ) {
        self.cloudKit = cloudKit
        self.pendingSync = pendingSync
        statusStore = cloudKit.statusStore
    }

    var currentState: SyncSettingsCloudState {
        Self.state(
            syncState: statusStore.syncState,
            accountState: statusStore.accountState,
            lastSyncDate: statusStore.lastSyncDate,
            queueSummary: pendingSync.queueSummary
        )
    }

    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> {
        Publishers.CombineLatest(
            Publishers.CombineLatest3(
                statusStore.$syncState,
                statusStore.$accountState,
                statusStore.$lastSyncDate
            ),
            pendingSync.queueSummaryUpdates
        )
        .map { status, queueSummary in
            Self.state(
                syncState: status.0,
                accountState: status.1,
                lastSyncDate: status.2,
                queueSummary: queueSummary
            )
        }
        .eraseToAnyPublisher()
    }

    func setSyncEnabled(_ enabled: Bool) {
        cloudKit.handleSyncToggle(enabled)
    }

    func checkAccountStatus() async {
        await cloudKit.refreshAccountStatus()
    }

    private static func state(
        syncState: CloudKitSyncState,
        accountState: CloudKitAccountState,
        lastSyncDate: Date? = nil,
        queueSummary: PendingCloudKitQueueSummary
    ) -> SyncSettingsCloudState {
        SyncSettingsCloudState(
            status: status(syncState.status),
            isAvailable: syncState.isAvailable,
            accountState: accountState,
            pendingOperationCount: queueSummary.pendingOperationCount,
            hasPendingFailure: queueSummary.hasPendingFailure,
            quarantinedOperationCount: queueSummary.quarantinedOperationCount,
            pendingQueueHealth: queueSummary.health,
            lastSuccessfulSyncDate: lastSyncDate
        )
    }

    private static func status(
        _ status: CloudKitSyncState.Status
    ) -> SyncSettingsCloudState.Status {
        switch status {
        case .idle:
            return .idle
        case .syncing:
            return .syncing
        case .error:
            return .error
        case .offline:
            return .offline
        case .disabled:
            return .disabled
        }
    }
}

@MainActor
private final class KeychainSyncSettingsAdapter: SyncSettingsCredentialSyncing {
    private let keychain: KeychainManager

    init(keychain: KeychainManager) {
        self.keychain = keychain
    }

    var currentState: SyncSettingsCredentialState {
        if !SyncSettings.isEnabled {
            return .storedOnThisDevice
        }
        return keychain.hasPendingCredentialSyncWork
            ? .needsAttention
            : .storedInICloudKeychain
    }

    func prepareCredentialStorage(isSyncEnabled: Bool) throws {
        try keychain.handleSyncToggle(isEnabled: isSyncEnabled)
    }

    func removeCredentialsFromICloud() throws {
        try keychain.removeCredentialsFromICloud()
    }
}

@MainActor
private final class AppSyncSettingsDataAdapter: SyncSettingsDataRefreshing {
    private let serverManager: ServerManager
    private let terminalTheme: TerminalThemeManager
    private let terminalAccessory: TerminalAccessoryPreferencesManager
    private let statsPreferences: PreferencesStore
    private let pendingSync: CloudKitSyncCoordinator

    init(
        serverManager: ServerManager,
        terminalTheme: TerminalThemeManager,
        terminalAccessory: TerminalAccessoryPreferencesManager,
        statsPreferences: PreferencesStore,
        pendingSync: CloudKitSyncCoordinator
    ) {
        self.serverManager = serverManager
        self.terminalTheme = terminalTheme
        self.terminalAccessory = terminalAccessory
        self.statsPreferences = statsPreferences
        self.pendingSync = pendingSync
    }

    func handleSyncDisabled() {
        serverManager.handleSyncDisabled()
    }

    func syncNow() async throws {
        await pendingSync.drainPendingMutations()
        await serverManager.loadData()
        guard serverManager.stateStore.ambiguousCloudRecovery == nil,
              serverManager.stateStore.error == nil else {
            throw SyncSettingsDataRefreshError.serverData
        }
        try await terminalTheme.refreshFromCloud()
        try await terminalAccessory.refreshFromCloud()
        try await statsPreferences.refreshFromCloud()
        await pendingSync.drainPendingMutations()
    }
}

private enum SyncSettingsDataRefreshError: Error {
    case serverData
}

@MainActor
private final class AppSyncSettingsContentSummaryAdapter: SyncSettingsContentSummarizing {
    private let serverManager: ServerManager
    private let keychain: KeychainManager
    private let terminalTheme: TerminalThemeManager

    init(
        serverManager: ServerManager,
        keychain: KeychainManager,
        terminalTheme: TerminalThemeManager
    ) {
        self.serverManager = serverManager
        self.keychain = keychain
        self.terminalTheme = terminalTheme
    }

    var currentSummary: SyncSettingsContentSummary {
        SyncSettingsContentSummary(
            workspaceCount: serverManager.workspaces.count,
            serverCount: serverManager.servers.count,
            customThemeCount: terminalTheme.customThemes.filter { !$0.isDeleted }.count,
            serverCredentialCount: serverManager.servers.filter(hasCredentials).count,
            reusableSSHKeyCount: keychain.getStoredSSHKeys().count
        )
    }

    private func hasCredentials(_ server: Server) -> Bool {
        (try? keychain.hasCredentials(for: server)) == true
    }
}

@MainActor
final class UserDefaultsSyncSettingsHistoryStore: SyncSettingsHistoryStoring {
    nonisolated static let lastSuccessfulSyncKey = "settings.sync.lastSuccessfulDate"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var lastSuccessfulSyncDate: Date? {
        guard let interval = defaults.object(forKey: Self.lastSuccessfulSyncKey) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func recordSuccessfulSync(at date: Date) throws {
        let interval = date.timeIntervalSince1970
        defaults.set(interval, forKey: Self.lastSuccessfulSyncKey)
        guard defaults.object(forKey: Self.lastSuccessfulSyncKey) as? Double == interval else {
            throw SyncSettingsHistoryError.persistenceFailed
        }
    }
}

private enum SyncSettingsHistoryError: Error {
    case persistenceFailed
}

@MainActor
enum SyncSettingsLiveComposition {
    static func makeCoordinator(
        cloudKit: CloudKitManager,
        keychain: KeychainManager,
        serverManager: ServerManager,
        terminalTheme: TerminalThemeManager,
        terminalAccessory: TerminalAccessoryPreferencesManager,
        statsPreferences: PreferencesStore,
        pendingSync: CloudKitSyncCoordinator,
        defaults: UserDefaults
    ) -> SyncSettingsCoordinator {
        SyncSettingsCoordinator(
            cloud: CloudKitSyncSettingsAdapter(
                cloudKit: cloudKit,
                pendingSync: pendingSync
            ),
            credentials: KeychainSyncSettingsAdapter(keychain: keychain),
            data: AppSyncSettingsDataAdapter(
                serverManager: serverManager,
                terminalTheme: terminalTheme,
                terminalAccessory: terminalAccessory,
                statsPreferences: statsPreferences,
                pendingSync: pendingSync
            ),
            content: AppSyncSettingsContentSummaryAdapter(
                serverManager: serverManager,
                keychain: keychain,
                terminalTheme: terminalTheme
            ),
            history: UserDefaultsSyncSettingsHistoryStore(defaults: defaults),
            runtime: runtimeInfo
        )
    }

    private static var runtimeInfo: SyncSettingsRuntimeInfo {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildVersion = info?["CFBundleVersion"] as? String ?? "unknown"
        #if os(iOS)
        let platform = "iOS \(Foundation.ProcessInfo.processInfo.operatingSystemVersionString)"
        #elseif os(macOS)
        let platform = "macOS \(Foundation.ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = Foundation.ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return SyncSettingsRuntimeInfo(
            appVersion: appVersion,
            buildVersion: buildVersion,
            platform: platform
        )
    }
}
