import Combine
import Foundation

nonisolated struct SyncSettingsCloudState: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case idle
        case syncing
        case error
        case offline
        case disabled
    }

    let status: Status
    let isAvailable: Bool
    let accountState: CloudKitAccountState
    let pendingOperationCount: Int
    let hasPendingFailure: Bool
    let quarantinedOperationCount: Int
    let pendingQueueHealth: PendingCloudKitQueueHealth
    let lastSuccessfulSyncDate: Date?

    init(
        status: Status,
        isAvailable: Bool,
        accountState: CloudKitAccountState,
        pendingOperationCount: Int,
        hasPendingFailure: Bool,
        quarantinedOperationCount: Int = 0,
        pendingQueueHealth: PendingCloudKitQueueHealth = .ready,
        lastSuccessfulSyncDate: Date?
    ) {
        self.status = status
        self.isAvailable = isAvailable
        self.accountState = accountState
        self.pendingOperationCount = pendingOperationCount
        self.hasPendingFailure = hasPendingFailure
        self.quarantinedOperationCount = quarantinedOperationCount
        self.pendingQueueHealth = pendingQueueHealth
        self.lastSuccessfulSyncDate = lastSuccessfulSyncDate
    }

    var outstandingOperationCount: Int {
        pendingOperationCount + quarantinedOperationCount
    }

    var hasBlockedPendingWork: Bool {
        quarantinedOperationCount > 0 || pendingQueueHealth == .migrationBlocked
    }
}

nonisolated enum SyncSettingsCredentialState: Equatable, Sendable {
    case storedInICloudKeychain
    case storedOnThisDevice
    case needsAttention
}

nonisolated enum SyncSettingsUserState: Equatable, Sendable {
    case readyToSync
    case upToDate
    case syncing
    case waitingForNetwork
    case signInToICloud
    case needsAttention
    case disabled
}

nonisolated enum SyncSettingsManualSyncState: Equatable, Sendable {
    case idle
    case running
    case success
    case waitingForNetwork
    case accountActionRequired
    case failure
}

nonisolated enum SyncSettingsErrorCategory: String, Equatable, Sendable {
    case account
    case cloudData
    case credentials
    case network
}

nonisolated struct SyncSettingsErrorRecord: Equatable, Sendable {
    let category: SyncSettingsErrorCategory
    let date: Date
}

nonisolated struct SyncSettingsRuntimeInfo: Equatable, Sendable {
    let appVersion: String
    let buildVersion: String
    let platform: String
}

nonisolated struct SyncSettingsContentSummary: Equatable, Sendable {
    let workspaceCount: Int
    let serverCount: Int
    let customThemeCount: Int
    let serverCredentialCount: Int
    let reusableSSHKeyCount: Int
}

nonisolated enum SyncSettingsAccountCategory: String, Equatable, Sendable {
    case available
    case checking
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unavailable

    init(_ state: CloudKitAccountState) {
        switch state {
        case .available:
            self = .available
        case .checking:
            self = .checking
        case .noAccount:
            self = .noAccount
        case .restricted:
            self = .restricted
        case .temporarilyUnavailable:
            self = .temporarilyUnavailable
        case .couldNotDetermine, .unknown, .failed:
            self = .unavailable
        case .disabled:
            self = .unavailable
        }
    }
}

nonisolated struct SyncSettingsDiagnostics: Equatable, Sendable {
    let state: SyncSettingsUserState
    let account: SyncSettingsAccountCategory
    let lastSuccessfulSyncDate: Date?
    let pendingOperationCount: Int
    let quarantinedOperationCount: Int
    let pendingQueueHealth: PendingCloudKitQueueHealth
    let lastError: SyncSettingsErrorRecord?
    let runtime: SyncSettingsRuntimeInfo

    var text: String {
        var lines = [
            "VVTerm Sync Diagnostics",
            "Status: \(state.diagnosticValue)",
            "iCloud Account: \(account.rawValue)",
            "Last Successful Sync: \(lastSuccessfulSyncDate.map(Self.format) ?? "none")",
            "Pending Changes: \(pendingOperationCount)",
            "Quarantined Changes: \(quarantinedOperationCount)",
            "Pending Queue: \(pendingQueueHealth.diagnosticValue)",
            "App Version: \(runtime.appVersion) (\(runtime.buildVersion))",
            "Platform: \(runtime.platform)",
        ]
        if let lastError {
            lines.append("Last Error Category: \(lastError.category.rawValue)")
            lines.append("Last Error Time: \(Self.format(lastError.date))")
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension PendingCloudKitQueueHealth {
    nonisolated var diagnosticValue: String {
        switch self {
        case .ready: "ready"
        case .migrationBlocked: "migrationBlocked"
        }
    }
}

private extension SyncSettingsUserState {
    nonisolated var diagnosticValue: String {
        switch self {
        case .readyToSync: "readyToSync"
        case .upToDate: "upToDate"
        case .syncing: "syncing"
        case .waitingForNetwork: "waitingForNetwork"
        case .signInToICloud: "signInToICloud"
        case .needsAttention: "needsAttention"
        case .disabled: "disabled"
        }
    }
}

@MainActor
protocol SyncSettingsCloudSyncing: AnyObject {
    var currentState: SyncSettingsCloudState { get }
    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> { get }

    func setSyncEnabled(_ enabled: Bool)
    func checkAccountStatus() async
}

@MainActor
protocol SyncSettingsCredentialSyncing: AnyObject {
    var currentState: SyncSettingsCredentialState { get }

    func prepareCredentialStorage(isSyncEnabled: Bool) throws
    func removeCredentialsFromICloud() throws
}

@MainActor
protocol SyncSettingsDataRefreshing: AnyObject {
    func handleSyncDisabled()
    func syncNow() async throws
}

@MainActor
protocol SyncSettingsContentSummarizing: AnyObject {
    var currentSummary: SyncSettingsContentSummary { get }
}

@MainActor
protocol SyncSettingsHistoryStoring: AnyObject {
    var lastSuccessfulSyncDate: Date? { get }
    func recordSuccessfulSync(at date: Date) throws
}

@MainActor
final class SyncSettingsCoordinator: ObservableObject {
    enum CredentialFailure: Equatable {
        case toggle
        case sync
        case removal
    }

    @Published private(set) var cloudState: SyncSettingsCloudState
    @Published private(set) var credentialState: SyncSettingsCredentialState
    @Published private(set) var credentialFailure: CredentialFailure?
    @Published private(set) var manualSyncState: SyncSettingsManualSyncState = .idle
    @Published private(set) var lastSuccessfulSyncDate: Date?
    @Published private(set) var lastError: SyncSettingsErrorRecord?
    @Published private(set) var contentSummary: SyncSettingsContentSummary

    private let cloud: any SyncSettingsCloudSyncing
    private let credentials: any SyncSettingsCredentialSyncing
    private let data: any SyncSettingsDataRefreshing
    private let content: any SyncSettingsContentSummarizing
    private let history: any SyncSettingsHistoryStoring
    private let runtime: SyncSettingsRuntimeInfo
    private let now: () -> Date
    private var cloudStateObservation: AnyCancellable?
    private var manualSyncOperationID = UUID()

    init(
        cloud: any SyncSettingsCloudSyncing,
        credentials: any SyncSettingsCredentialSyncing,
        data: any SyncSettingsDataRefreshing,
        content: any SyncSettingsContentSummarizing,
        history: any SyncSettingsHistoryStoring,
        runtime: SyncSettingsRuntimeInfo,
        now: @escaping () -> Date = Date.init
    ) {
        self.cloud = cloud
        self.credentials = credentials
        self.data = data
        self.content = content
        self.history = history
        self.runtime = runtime
        self.now = now
        cloudState = cloud.currentState
        credentialState = credentials.currentState
        contentSummary = content.currentSummary
        lastSuccessfulSyncDate = [
            history.lastSuccessfulSyncDate,
            cloud.currentState.lastSuccessfulSyncDate,
        ]
        .compactMap { $0 }
        .max()
        cloudStateObservation = cloud.stateUpdates
            .removeDuplicates()
            .sink { [weak self] state in
                self?.cloudState = state
                self?.acceptCloudSuccessDate(state.lastSuccessfulSyncDate)
            }
    }

    var userState: SyncSettingsUserState {
        if case .disabled = cloudState.status {
            return .disabled
        }
        if manualSyncState == .running || cloudState.status == .syncing {
            return .syncing
        }
        if credentialState == .needsAttention {
            return .needsAttention
        }

        switch cloudState.accountState {
        case .noAccount:
            return .signInToICloud
        case .temporarilyUnavailable:
            return .waitingForNetwork
        case .restricted, .couldNotDetermine, .unknown, .failed:
            return .needsAttention
        case .checking:
            return .syncing
        case .disabled:
            return .disabled
        case .available:
            break
        }

        switch manualSyncState {
        case .waitingForNetwork:
            return .waitingForNetwork
        case .accountActionRequired:
            return .signInToICloud
        case .failure:
            return .needsAttention
        case .idle, .running, .success:
            break
        }

        switch cloudState.status {
        case .offline:
            return .waitingForNetwork
        case .error:
            return .needsAttention
        case .disabled:
            return .disabled
        case .idle, .syncing:
            break
        }

        if cloudState.hasBlockedPendingWork {
            return .needsAttention
        }

        if cloudState.pendingOperationCount > 0 {
            return cloudState.hasPendingFailure ? .needsAttention : .waitingForNetwork
        }
        return lastSuccessfulSyncDate == nil ? .readyToSync : .upToDate
    }

    var canSyncNow: Bool {
        cloudState.isAvailable && manualSyncState != .running
    }

    var diagnostics: SyncSettingsDiagnostics {
        SyncSettingsDiagnostics(
            state: userState,
            account: SyncSettingsAccountCategory(cloudState.accountState),
            lastSuccessfulSyncDate: lastSuccessfulSyncDate,
            pendingOperationCount: cloudState.pendingOperationCount,
            quarantinedOperationCount: cloudState.quarantinedOperationCount,
            pendingQueueHealth: cloudState.pendingQueueHealth,
            lastError: lastError,
            runtime: runtime
        )
    }

    @discardableResult
    func setSyncEnabled(_ enabled: Bool) -> Bool {
        invalidateManualSync()
        do {
            try credentials.prepareCredentialStorage(isSyncEnabled: enabled)
        } catch {
            credentialFailure = .toggle
            credentialState = .needsAttention
            recordError(.credentials)
            return false
        }

        credentialFailure = nil
        credentialState = enabled ? .storedInICloudKeychain : .storedOnThisDevice
        if !enabled {
            data.handleSyncDisabled()
        }
        cloud.setSyncEnabled(enabled)
        refreshSnapshots()
        return true
    }

    func syncNow() async {
        guard manualSyncState != .running else { return }
        manualSyncOperationID = UUID()
        let operationID = manualSyncOperationID
        manualSyncState = .running
        credentialFailure = nil

        await cloud.checkAccountStatus()
        guard isCurrentManualSync(operationID) else { return }
        refreshSnapshots()

        guard cloudState.isAvailable else {
            finishUnavailableSync()
            return
        }

        var credentialSyncFailed = false
        do {
            try credentials.prepareCredentialStorage(isSyncEnabled: true)
            credentialState = credentials.currentState
        } catch {
            credentialSyncFailed = true
            credentialFailure = .sync
            credentialState = .needsAttention
            recordError(.credentials)
        }

        do {
            try await data.syncNow()
        } catch is CancellationError {
            guard isCurrentManualSync(operationID) else { return }
            manualSyncState = .idle
            refreshSnapshots()
            return
        } catch {
            guard isCurrentManualSync(operationID) else { return }
            manualSyncState = .failure
            recordError(.cloudData)
            refreshSnapshots()
            return
        }

        guard isCurrentManualSync(operationID) else { return }
        refreshSnapshots()
        if credentialSyncFailed {
            manualSyncState = .failure
            return
        }
        if cloudState.status == .offline {
            manualSyncState = .waitingForNetwork
            recordError(.network)
            return
        }
        if cloudState.status == .error || cloudState.hasPendingFailure || cloudState.hasBlockedPendingWork {
            manualSyncState = .failure
            recordError(.cloudData)
            return
        }
        if cloudState.pendingOperationCount > 0 {
            manualSyncState = .waitingForNetwork
            recordError(.network)
            return
        }

        let successDate = now()
        guard isCurrentManualSync(operationID) else { return }
        do {
            try history.recordSuccessfulSync(at: successDate)
            lastSuccessfulSyncDate = successDate
            lastError = nil
            manualSyncState = .success
        } catch {
            manualSyncState = .failure
            recordError(.cloudData)
        }
    }

    func checkICloudStatus() async {
        guard manualSyncState != .running else { return }
        await cloud.checkAccountStatus()
        refreshSnapshots()
    }

    @discardableResult
    func removeCredentialsFromICloud() -> Bool {
        do {
            try credentials.removeCredentialsFromICloud()
            credentialFailure = nil
            credentialState = credentials.currentState
            return true
        } catch {
            credentialFailure = .removal
            credentialState = .needsAttention
            recordError(.credentials)
            return false
        }
    }

    func refreshSnapshots() {
        cloudState = cloud.currentState
        contentSummary = content.currentSummary
        acceptCloudSuccessDate(cloudState.lastSuccessfulSyncDate)
        if credentialFailure == nil {
            credentialState = credentials.currentState
        }
    }

    private func finishUnavailableSync() {
        switch cloudState.accountState {
        case .noAccount:
            manualSyncState = .accountActionRequired
            recordError(.account)
        case .temporarilyUnavailable:
            manualSyncState = .waitingForNetwork
            recordError(.network)
        case .checking, .available, .restricted, .couldNotDetermine, .unknown, .failed, .disabled:
            manualSyncState = .failure
            recordError(.account)
        }
    }

    private func invalidateManualSync() {
        manualSyncOperationID = UUID()
        manualSyncState = .idle
    }

    private func isCurrentManualSync(_ operationID: UUID) -> Bool {
        manualSyncOperationID == operationID
    }

    private func recordError(_ category: SyncSettingsErrorCategory) {
        lastError = SyncSettingsErrorRecord(category: category, date: now())
    }

    private func acceptCloudSuccessDate(_ date: Date?) {
        guard let date, date > (lastSuccessfulSyncDate ?? .distantPast) else { return }
        lastSuccessfulSyncDate = date
        do {
            try history.recordSuccessfulSync(at: date)
        } catch {
            recordError(.cloudData)
        }
    }
}
