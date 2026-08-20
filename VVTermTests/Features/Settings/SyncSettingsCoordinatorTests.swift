import Combine
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class SyncSettingsActionLog {
    var events: [String] = []
}

@MainActor
private final class SyncSettingsCloudSpy: SyncSettingsCloudSyncing {
    let states: CurrentValueSubject<SyncSettingsCloudState, Never>
    let actionLog: SyncSettingsActionLog
    var toggles: [Bool] = []
    var accountCheckCount = 0

    init(
        state: SyncSettingsCloudState = .available,
        actionLog: SyncSettingsActionLog? = nil
    ) {
        states = CurrentValueSubject(state)
        self.actionLog = actionLog ?? SyncSettingsActionLog()
    }

    var currentState: SyncSettingsCloudState { states.value }
    var stateUpdates: AnyPublisher<SyncSettingsCloudState, Never> {
        states.eraseToAnyPublisher()
    }

    func setSyncEnabled(_ enabled: Bool) {
        toggles.append(enabled)
        actionLog.events.append("cloud:\(enabled)")
    }

    func checkAccountStatus() async {
        accountCheckCount += 1
    }
}

@MainActor
private final class SyncSettingsCredentialSpy: SyncSettingsCredentialSyncing {
    let actionLog: SyncSettingsActionLog
    var currentState: SyncSettingsCredentialState = .storedInICloudKeychain
    var preparedValues: [Bool] = []
    var prepareError: Error?
    var removalCount = 0
    var removalError: Error?

    init(actionLog: SyncSettingsActionLog? = nil) {
        self.actionLog = actionLog ?? SyncSettingsActionLog()
    }

    func prepareCredentialStorage(isSyncEnabled: Bool) throws {
        preparedValues.append(isSyncEnabled)
        actionLog.events.append("credentials:\(isSyncEnabled)")
        if let prepareError { throw prepareError }
        currentState = isSyncEnabled ? .storedInICloudKeychain : .storedOnThisDevice
    }

    func removeCredentialsFromICloud() throws {
        removalCount += 1
        if let removalError { throw removalError }
        currentState = .storedOnThisDevice
    }
}

@MainActor
private final class SyncSettingsDataSpy: SyncSettingsDataRefreshing {
    let actionLog: SyncSettingsActionLog
    var disabledCount = 0
    var syncCount = 0
    var syncError: Error?
    var suspendsSync = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(actionLog: SyncSettingsActionLog? = nil) {
        self.actionLog = actionLog ?? SyncSettingsActionLog()
    }

    func handleSyncDisabled() {
        disabledCount += 1
        actionLog.events.append("data-disabled")
    }

    func syncNow() async throws {
        syncCount += 1
        actionLog.events.append("data-synced")
        if suspendsSync {
            suspendsSync = false
            await withCheckedContinuation { continuation = $0 }
        }
        if let syncError { throw syncError }
    }

    func resumeSync() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SyncSettingsContentSpy: SyncSettingsContentSummarizing {
    var currentSummary = SyncSettingsContentSummary(
        workspaceCount: 2,
        serverCount: 7,
        customThemeCount: 3,
        serverCredentialCount: 6,
        reusableSSHKeyCount: 4
    )
}

@MainActor
private final class SyncSettingsHistorySpy: SyncSettingsHistoryStoring {
    var lastSuccessfulSyncDate: Date?
    var recordedDates: [Date] = []
    var error: Error?

    func recordSuccessfulSync(at date: Date) throws {
        if let error { throw error }
        recordedDates.append(date)
        lastSuccessfulSyncDate = date
    }
}

@MainActor
struct SyncSettingsCoordinatorTests {
    private enum TestError: Error {
        case failed
    }

    @Test
    func publishesCloudStateAndChecksAccountWithoutStartingDataSync() async {
        let cloud = SyncSettingsCloudSpy()
        let data = SyncSettingsDataSpy()
        let coordinator = makeCoordinator(cloud: cloud, data: data)
        let updatedState = SyncSettingsCloudState(
            status: .offline,
            isAvailable: false,
            accountState: .temporarilyUnavailable,
            pendingOperationCount: 2,
            hasPendingFailure: false,
            lastSuccessfulSyncDate: nil
        )

        cloud.states.send(updatedState)
        await coordinator.checkICloudStatus()

        #expect(coordinator.cloudState == updatedState)
        #expect(cloud.accountCheckCount == 1)
        #expect(data.syncCount == 0)
    }

    @Test
    func refreshSnapshotsPublishesDerivedContentCounts() {
        let content = SyncSettingsContentSpy()
        let coordinator = makeCoordinator(content: content)
        let updated = SyncSettingsContentSummary(
            workspaceCount: 3,
            serverCount: 8,
            customThemeCount: 4,
            serverCredentialCount: 7,
            reusableSSHKeyCount: 5
        )

        content.currentSummary = updated
        coordinator.refreshSnapshots()

        #expect(coordinator.contentSummary == updated)
    }

    @Test
    func recordsSuccessfulBackgroundCloudSyncDate() async {
        let cloud = SyncSettingsCloudSpy()
        let history = SyncSettingsHistorySpy()
        let coordinator = makeCoordinator(cloud: cloud, history: history)
        let successDate = Date(timeIntervalSince1970: 123)

        cloud.states.send(
            SyncSettingsCloudState(
                status: .idle,
                isAvailable: true,
                accountState: .available,
                pendingOperationCount: 0,
                hasPendingFailure: false,
                lastSuccessfulSyncDate: successDate
            )
        )
        await Task.yield()

        #expect(coordinator.lastSuccessfulSyncDate == successDate)
        #expect(history.recordedDates == [successDate])
    }

    @Test
    func enablingSyncPreparesCredentialsBeforeCloudToggle() {
        let actionLog = SyncSettingsActionLog()
        let cloud = SyncSettingsCloudSpy(actionLog: actionLog)
        let credentials = SyncSettingsCredentialSpy(actionLog: actionLog)
        let data = SyncSettingsDataSpy(actionLog: actionLog)
        let coordinator = makeCoordinator(
            cloud: cloud,
            credentials: credentials,
            data: data
        )

        #expect(coordinator.setSyncEnabled(true))
        #expect(credentials.preparedValues == [true])
        #expect(cloud.toggles == [true])
        #expect(data.disabledCount == 0)
        #expect(data.syncCount == 0)
        #expect(actionLog.events == ["credentials:true", "cloud:true"])
    }

    @Test
    func disablingSyncKeepsLocalDataAndStopsSyncBeforeCloudToggle() {
        let actionLog = SyncSettingsActionLog()
        let cloud = SyncSettingsCloudSpy(actionLog: actionLog)
        let credentials = SyncSettingsCredentialSpy(actionLog: actionLog)
        let data = SyncSettingsDataSpy(actionLog: actionLog)
        credentials.prepareError = TestError.failed
        let coordinator = makeCoordinator(
            cloud: cloud,
            credentials: credentials,
            data: data
        )

        #expect(!coordinator.setSyncEnabled(true))
        #expect(coordinator.credentialFailure == .toggle)
        #expect(cloud.toggles.isEmpty)
        #expect(data.disabledCount == 0)

        credentials.prepareError = nil
        actionLog.events.removeAll()
        #expect(coordinator.setSyncEnabled(false))
        #expect(coordinator.credentialFailure == nil)
        #expect(credentials.preparedValues == [true, false])
        #expect(data.disabledCount == 1)
        #expect(cloud.toggles == [false])
        #expect(actionLog.events == ["credentials:false", "data-disabled", "cloud:false"])
        #expect(coordinator.credentialState == .storedOnThisDevice)
    }

    @Test
    func syncNowRunsCompleteOwnerOnceAndRecordsRealSuccess() async {
        let successDate = Date(timeIntervalSince1970: 1_234)
        let cloud = SyncSettingsCloudSpy()
        let credentials = SyncSettingsCredentialSpy()
        let data = SyncSettingsDataSpy()
        let history = SyncSettingsHistorySpy()
        let coordinator = makeCoordinator(
            cloud: cloud,
            credentials: credentials,
            data: data,
            history: history,
            now: { successDate }
        )

        await coordinator.syncNow()

        #expect(cloud.accountCheckCount == 1)
        #expect(credentials.preparedValues == [true])
        #expect(data.syncCount == 1)
        #expect(history.recordedDates == [successDate])
        #expect(coordinator.lastSuccessfulSyncDate == successDate)
        #expect(coordinator.manualSyncState == .success)
        #expect(coordinator.userState == .upToDate)
    }

    @Test
    func repeatedSyncNowCallsDoNotOverlap() async {
        let data = SyncSettingsDataSpy()
        data.suspendsSync = true
        let coordinator = makeCoordinator(data: data)

        let first = Task { await coordinator.syncNow() }
        await Task.yield()
        let second = Task { await coordinator.syncNow() }
        await Task.yield()

        #expect(data.syncCount == 1)
        #expect(coordinator.manualSyncState == .running)

        data.resumeSync()
        await first.value
        await second.value
        #expect(data.syncCount == 1)
    }

    @Test
    func syncToggleInvalidatesAnOlderManualSync() async {
        let data = SyncSettingsDataSpy()
        data.suspendsSync = true
        let history = SyncSettingsHistorySpy()
        let coordinator = makeCoordinator(data: data, history: history)

        let staleSync = Task { await coordinator.syncNow() }
        while data.syncCount == 0 {
            await Task.yield()
        }

        #expect(coordinator.setSyncEnabled(false))
        #expect(coordinator.setSyncEnabled(true))
        await coordinator.syncNow()

        #expect(data.syncCount == 2)
        #expect(history.recordedDates.count == 1)
        #expect(coordinator.manualSyncState == .success)

        data.resumeSync()
        await staleSync.value

        #expect(history.recordedDates.count == 1)
        #expect(coordinator.manualSyncState == .success)
        #expect(coordinator.userState == .upToDate)
    }

    @Test
    func offlineSyncKeepsPendingChangesAndReportsWaiting() async {
        let cloud = SyncSettingsCloudSpy(
            state: SyncSettingsCloudState(
                status: .offline,
                isAvailable: false,
                accountState: .temporarilyUnavailable,
                pendingOperationCount: 3,
                hasPendingFailure: false,
                lastSuccessfulSyncDate: nil
            )
        )
        let data = SyncSettingsDataSpy()
        let coordinator = makeCoordinator(cloud: cloud, data: data)

        await coordinator.syncNow()

        #expect(data.syncCount == 0)
        #expect(coordinator.cloudState.pendingOperationCount == 3)
        #expect(coordinator.manualSyncState == .waitingForNetwork)
        #expect(coordinator.userState == .waitingForNetwork)
    }

    @Test
    func missingAccountReportsSignInAction() async {
        let cloud = SyncSettingsCloudSpy(
            state: SyncSettingsCloudState(
                status: .offline,
                isAvailable: false,
                accountState: .noAccount,
                pendingOperationCount: 0,
                hasPendingFailure: false,
                lastSuccessfulSyncDate: nil
            )
        )
        let coordinator = makeCoordinator(cloud: cloud)

        await coordinator.syncNow()

        #expect(coordinator.manualSyncState == .accountActionRequired)
        #expect(coordinator.userState == .signInToICloud)
    }

    @Test
    func cloudSuccessDoesNotHideCredentialFailure() async {
        let credentials = SyncSettingsCredentialSpy()
        credentials.prepareError = TestError.failed
        let data = SyncSettingsDataSpy()
        let history = SyncSettingsHistorySpy()
        let coordinator = makeCoordinator(
            credentials: credentials,
            data: data,
            history: history
        )

        await coordinator.syncNow()

        #expect(data.syncCount == 1)
        #expect(coordinator.credentialState == .needsAttention)
        #expect(coordinator.credentialFailure == .sync)
        #expect(coordinator.manualSyncState == .failure)
        #expect(history.recordedDates.isEmpty)
    }

    @Test
    func quarantinedMutationPreventsUpToDateAndManualSuccess() async {
        let cloud = SyncSettingsCloudSpy(
            state: SyncSettingsCloudState(
                status: .idle,
                isAvailable: true,
                accountState: .available,
                pendingOperationCount: 0,
                hasPendingFailure: false,
                quarantinedOperationCount: 1,
                lastSuccessfulSyncDate: nil
            )
        )
        let history = SyncSettingsHistorySpy()
        let coordinator = makeCoordinator(cloud: cloud, history: history)

        await coordinator.syncNow()

        #expect(coordinator.manualSyncState == .failure)
        #expect(coordinator.userState == .needsAttention)
        #expect(history.recordedDates.isEmpty)
        #expect(coordinator.diagnostics.pendingOperationCount == 0)
        #expect(coordinator.diagnostics.quarantinedOperationCount == 1)
    }

    @Test
    func blockedQueueMigrationPreventsUpToDateAndManualSuccess() async {
        let cloud = SyncSettingsCloudSpy(
            state: SyncSettingsCloudState(
                status: .idle,
                isAvailable: true,
                accountState: .available,
                pendingOperationCount: 0,
                hasPendingFailure: false,
                pendingQueueHealth: .migrationBlocked,
                lastSuccessfulSyncDate: nil
            )
        )
        let history = SyncSettingsHistorySpy()
        let coordinator = makeCoordinator(cloud: cloud, history: history)

        await coordinator.syncNow()

        #expect(coordinator.manualSyncState == .failure)
        #expect(coordinator.userState == .needsAttention)
        #expect(history.recordedDates.isEmpty)
        #expect(coordinator.diagnostics.pendingQueueHealth == .migrationBlocked)
    }

    @Test
    func availableCloudWithoutSuccessfulSyncReportsReadyToSync() {
        let coordinator = makeCoordinator()

        #expect(coordinator.userState == .readyToSync)
        #expect(
            SyncSettingsContentSyncState(
                syncEnabled: true,
                userState: coordinator.userState,
                lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate
            ) == .included
        )
    }

    @Test
    func credentialRemovalIsASeparateConfirmedAction() {
        let credentials = SyncSettingsCredentialSpy()
        let coordinator = makeCoordinator(credentials: credentials)

        #expect(coordinator.removeCredentialsFromICloud())
        #expect(credentials.removalCount == 1)
        #expect(coordinator.credentialState == .storedOnThisDevice)
    }

    @Test
    func diagnosticsContainOnlyAllowlistedOperationalFields() async {
        let credentials = SyncSettingsCredentialSpy()
        credentials.prepareError = TestError.failed
        let coordinator = makeCoordinator(
            credentials: credentials,
            runtime: SyncSettingsRuntimeInfo(
                appVersion: "2.15",
                buildVersion: "419",
                platform: "iOS 27.0"
            ),
            now: { Date(timeIntervalSince1970: 0) }
        )

        await coordinator.syncNow()
        let diagnostics = coordinator.diagnostics.text

        #expect(diagnostics.contains("Status: needsAttention"))
        #expect(diagnostics.contains("iCloud Account: available"))
        #expect(diagnostics.contains("Pending Changes: 0"))
        #expect(diagnostics.contains("Last Error Category: credentials"))
        #expect(diagnostics.contains("App Version: 2.15 (419)"))
        #expect(diagnostics.contains("Platform: iOS 27.0"))
        #expect(!diagnostics.localizedCaseInsensitiveContains("password"))
        #expect(!diagnostics.localizedCaseInsensitiveContains("private key"))
        #expect(!diagnostics.localizedCaseInsensitiveContains("example.com"))
        #expect(!diagnostics.localizedCaseInsensitiveContains("oauth token"))
    }

    private func makeCoordinator(
        cloud: SyncSettingsCloudSpy? = nil,
        credentials: SyncSettingsCredentialSpy? = nil,
        data: SyncSettingsDataSpy? = nil,
        content: SyncSettingsContentSpy? = nil,
        history: SyncSettingsHistorySpy? = nil,
        runtime: SyncSettingsRuntimeInfo = .testValue,
        now: @escaping () -> Date = Date.init
    ) -> SyncSettingsCoordinator {
        SyncSettingsCoordinator(
            cloud: cloud ?? SyncSettingsCloudSpy(),
            credentials: credentials ?? SyncSettingsCredentialSpy(),
            data: data ?? SyncSettingsDataSpy(),
            content: content ?? SyncSettingsContentSpy(),
            history: history ?? SyncSettingsHistorySpy(),
            runtime: runtime,
            now: now
        )
    }
}

private extension SyncSettingsCloudState {
    static let available = SyncSettingsCloudState(
        status: .idle,
        isAvailable: true,
        accountState: .available,
        pendingOperationCount: 0,
        hasPendingFailure: false,
        lastSuccessfulSyncDate: nil
    )
}

private extension SyncSettingsRuntimeInfo {
    static let testValue = SyncSettingsRuntimeInfo(
        appVersion: "test",
        buildVersion: "test",
        platform: "test"
    )
}
