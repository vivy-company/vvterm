import Combine
import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class DependencyTestSnapshotStore: TerminalTabSnapshotStoring {
    private var data: Data?

    func loadSnapshotData() -> Data? {
        data
    }

    func saveSnapshotData(_ data: Data) {
        self.data = data
    }

    func removeSnapshotData() {
        data = nil
    }
}

private final class DependencyTestETResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

private actor TerminalAuthorizationGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }

    func resolve(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class TerminalEffectRecorder {
    var authorizeResult = true
    var authorizationGate: TerminalAuthorizationGate?
    private(set) var authorizationRequests: [UUID] = []
    private(set) var initialConnectionPreparations: [UUID] = []
    private(set) var liveActivityRefreshCount = 0
    private(set) var successfulConnections: [(UUID, String)] = []
    private(set) var detectedSystems: [(UUID, RemoteSystemIdentity)] = []
    private(set) var sessionEndStates: [Bool] = []
    private(set) var splitPaneCount = 0

    func effects() -> TerminalSessionApplicationEffects {
        TerminalSessionApplicationEffects(
            authorizeServer: { [self] server in
                authorizationRequests.append(server.id)
                if let authorizationGate {
                    return await authorizationGate.wait()
                }
                return authorizeResult
            },
            prepareInitialConnection: { [self] server in
                initialConnectionPreparations.append(server.id)
            },
            refreshLiveActivity: { [self] _ in
                liveActivityRefreshCount += 1
            },
            recordSuccessfulConnection: { [self] id, transport in
                successfulConnections.append((id, transport))
            },
            publishDetectedSystem: { [self] server, identity in
                detectedSystems.append((server.id, identity))
            },
            noteTerminalSessionEnded: { [self] otherTerminalsActive in
                sessionEndStates.append(otherTerminalsActive)
            },
            recordSplitPaneCreated: { [self] in
                splitPaneCount += 1
            }
        )
    }
}

private actor RecordingTerminalRemoteTmuxService: TerminalRemoteSessionServicing {
    nonisolated let backendMetadata = [RemoteSessionBackendMetadata(
        identifier: .tmux,
        displayName: "tmux",
        installationGuideURL: URL(string: "https://github.com/tmux/tmux/wiki/Installing")!,
        managedStartupCommandSupport: .supported
    )]
    private var killedSessions: [RemoteSessionIdentifier] = []
    private var availabilityProbes = 0
    private var cleanupKeepSets: [Set<RemoteSessionIdentifier>] = []
    private var requests: [RemoteSessionLaunchRequest] = []
    private var directoryRequests = 0
    private let availabilityResult: RemoteSessionAvailability
    private let readDirectory: @Sendable () async -> String?
    private var failNextCleanup: Bool

    init(
        availabilityResult: RemoteSessionAvailability = .unsupportedEnvironment,
        readDirectory: @escaping @Sendable () async -> String? = { nil },
        failNextCleanup: Bool = false
    ) {
        self.availabilityResult = availabilityResult
        self.readDirectory = readDirectory
        self.failNextCleanup = failNextCleanup
    }

    func killedSessionIdentifiers() -> [RemoteSessionIdentifier] {
        killedSessions
    }

    func availabilityProbeCount() -> Int {
        availabilityProbes
    }

    func lastCleanupKeepSet() -> Set<RemoteSessionIdentifier>? {
        cleanupKeepSets.last
    }

    func launchRequests() -> [RemoteSessionLaunchRequest] {
        requests
    }

    func directoryRequestCount() -> Int { directoryRequests }

    func availability(
        for backendIdentifier: RemoteSessionBackendIdentifier,
        using client: SSHClient
    ) async -> RemoteSessionAvailability {
        availabilityProbes += 1
        return availabilityResult
    }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        []
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) async throws -> RemoteSessionBackendLaunchPlan {
        requests.append(request)
        return RemoteSessionBackendLaunchPlan(
            command: "test-launch",
            presenceProbe: RemoteSessionPresenceProbe(
                command: "test-presence",
                existsMarker: "test-exists",
                missingMarker: "test-missing"
            )
        )
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async {
        killedSessions.append(identifier)
    }

    func cleanupSessions(
        keeping identifiers: @escaping @Sendable () async throws -> Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws {
        if failNextCleanup {
            failNextCleanup = false
            throw SSHCommandExitError(exitStatus: 1)
        }
        cleanupKeepSets.append(try await identifiers())
    }

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async -> String? {
        directoryRequests += 1
        return await readDirectory()
    }
}

private actor RecordingTerminalRemoteMoshService: TerminalRemoteMoshServicing {
    private var installationCount = 0

    func installCount() -> Int {
        installationCount
    }

    func installMoshServer(using client: SSHClient) async throws {
        installationCount += 1
    }
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerDependencyIsolationTests {
    enum DirectoryRefreshOutcome: CaseIterable {
        case apply
        case cancel
        case newerLocalDirectory
    }

    @Test(arguments: DirectoryRefreshOutcome.allCases)
    func directoryRefreshRespectsItsOwnerAndNewerUpdates(_ outcome: DirectoryRefreshOutcome) async throws {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let remoteSessions = RecordingTerminalRemoteTmuxService(readDirectory: {
            signal.yield(())
            for await _ in released { break }
            return "/remote-current"
        })
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(), remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(), deviceID: "directory-refresh"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Directory")
        install(tab, in: manager)
        manager.sessionState.updatePane(tab.rootPaneId) { $0.workingDirectory = "/saved" }
        manager.remoteSessionCoordinator.setAttachment(
            for: tab.rootPaneId,
            identifier: try RemoteSessionIdentifier(backendIdentifier: .tmux, validating: "managed"),
            ownership: .managed
        )
        manager.remoteSessionCoordinator.directoryRefreshes[tab.rootPaneId] = .pending(
            client: .testing(), runtime: try directoryTestRuntime()
        )
        manager.remoteSessionCoordinator.startDirectoryRefresh(for: tab.rootPaneId)
        guard case .running(let task) = manager.remoteSessionCoordinator.directoryRefreshes[tab.rootPaneId] else {
            Issue.record("Directory refresh did not start")
            await manager.resetForTesting()
            return
        }
        for await _ in started { break }
        switch outcome {
        case .apply: break
        case .cancel: manager.remoteSessionCoordinator.clearRuntimeState(for: tab.rootPaneId)
        case .newerLocalDirectory:
            manager.sessionState.updatePane(tab.rootPaneId) { $0.workingDirectory = "/newer-local" }
        }
        release.yield(())
        await task.value
        let expected = switch outcome {
        case .apply: "/remote-current"
        case .cancel: "/saved"
        case .newerLocalDirectory: "/newer-local"
        }
        #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.workingDirectory == expected)
        #expect(manager.remoteSessionCoordinator.directoryRefreshes.isEmpty)
        await manager.resetForTesting()
    }

    @Test
    func splitStillReadsItsSourceDirectoryBeforeLaunch() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService(readDirectory: { "/source-current" })
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(), remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(), deviceID: "split-directory"
        )
        let source = TerminalTab(serverId: UUID(), title: "Source")
        let split = TerminalTab(serverId: source.serverId, title: "Split")
        install(source, in: manager)
        install(split, in: manager)
        manager.sessionState.updatePane(split.rootPaneId) {
            $0.seedPaneId = source.rootPaneId
            $0.workingDirectory = "/saved"
        }
        manager.remoteSessionCoordinator.setAttachment(
            for: source.rootPaneId,
            identifier: try RemoteSessionIdentifier(backendIdentifier: .tmux, validating: "source"),
            ownership: .managed
        )
        let directory = await manager.remoteSessionCoordinator.resolveWorkingDirectory(
            for: split.rootPaneId, using: .testing(), runtime: try directoryTestRuntime()
        )
        #expect(directory == "/source-current")
        #expect(await remoteSessions.directoryRequestCount() == 1)
        await manager.resetForTesting()
    }

    private func directoryTestRuntime() throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(validating: "/usr/bin/tmux"),
            implementationVariant: "tmux-posix", rawVersion: "tmux 3.5",
            semanticVersion: .init(major: 3, minor: 5, patch: 0),
            shellFamily: .posix, shellExecutable: "sh"
        ))
    }

    @Test
    func openingTheFirstTabPreparesTheConnectionOnce() async throws {
        let effects = TerminalEffectRecorder()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: effects,
            remoteSessions: RecordingTerminalRemoteTmuxService(),
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "initial-connection"
        )
        let server = makeServer()

        _ = try await manager.openTab(for: server)
        _ = try await manager.openTab(for: server)

        #expect(effects.initialConnectionPreparations == [server.id])
        await manager.resetForTesting()
    }

    @Test(arguments: [false, true], [false, true])
    func cleanupWaitsForAttachmentAndKeepsEveryServerProfile(cancelBeforeAttachment: Bool, failFirstAttempt: Bool) async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService(failNextCleanup: failFirstAttempt)
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            remoteSessionEnabled: true,
            startupBehavior: .createManaged,
            deviceID: "shared-host-device"
        )
        let firstTab = TerminalTab(serverId: UUID(), title: "First profile")
        let secondTab = TerminalTab(serverId: UUID(), title: "Second profile")
        install(firstTab, in: manager)
        install(secondTab, in: manager)
        let firstIdentifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "first-profile-session"
        )
        let secondIdentifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "second-profile-session"
        )
        manager.remoteSessionCoordinator.setAttachment(
            for: firstTab.rootPaneId,
            identifier: firstIdentifier,
            ownership: .managed
        )
        manager.remoteSessionCoordinator.setAttachment(
            for: secondTab.rootPaneId,
            identifier: secondIdentifier,
            ownership: .managed
        )

        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(
                for: firstTab.rootPaneId,
                client: client
            )
        )
        let probe = RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(validating: "/usr/bin/tmux"),
            implementationVariant: "tmux-posix",
            rawVersion: "tmux 3.5",
            semanticVersion: RemoteSessionSemanticVersion(major: 3, minor: 5, patch: 0),
            shellFamily: .posix,
            shellExecutable: "sh"
        )

        _ = try await manager.remoteSessionCoordinator.startupPlan(
            for: firstTab.rootPaneId,
            serverID: firstTab.serverId,
            client: client,
            startToken: startToken,
            availabilityResolver: { .available(probe) }
        )

        #expect(await remoteSessions.lastCleanupKeepSet() == nil)
        #expect(await remoteSessions.directoryRequestCount() == 0)
        if cancelBeforeAttachment {
            manager.remoteSessionCoordinator.clearRuntimeState(for: firstTab.rootPaneId)
        }
        manager.remoteSessionCoordinator.confirmManagedSession(for: firstTab.rootPaneId)
        if case .running(let task) = manager.remoteSessionCoordinator.directoryRefreshes[firstTab.rootPaneId] {
            await task.value
        }
        for state in manager.remoteSessionCoordinator.cleanupStates.values {
            if case .running(_, let task) = state { await task.value }
        }
        if failFirstAttempt && !cancelBeforeAttachment {
            #expect(manager.remoteSessionCoordinator.cleanupStates.isEmpty)
            #expect(await remoteSessions.lastCleanupKeepSet() == nil)
            _ = try await manager.remoteSessionCoordinator.startupPlan(
                for: firstTab.rootPaneId, serverID: firstTab.serverId,
                client: client, startToken: startToken,
                availabilityResolver: { .available(probe) }
            )
            manager.remoteSessionCoordinator.confirmManagedSession(for: firstTab.rootPaneId)
            if case .running(let task) = manager.remoteSessionCoordinator.directoryRefreshes[firstTab.rootPaneId] {
                await task.value
            }
            for state in manager.remoteSessionCoordinator.cleanupStates.values {
                if case .running(_, let task) = state { await task.value }
            }
            #expect(manager.remoteSessionCoordinator.cleanupStates.values.contains {
                if case .completed = $0 { return true }
                return false
            })
        }
        if cancelBeforeAttachment {
            #expect(await remoteSessions.lastCleanupKeepSet() == nil)
            #expect(await remoteSessions.directoryRequestCount() == 0)
        } else {
            #expect(await remoteSessions.lastCleanupKeepSet() == [firstIdentifier, secondIdentifier])
            #expect(await remoteSessions.directoryRequestCount() == (failFirstAttempt ? 2 : 1))
        }
        await manager.resetForTesting()
    }

    enum ConnectionApprovalOutcome: CaseIterable { case approved, denied, cancelled }

    @Test(arguments: ConnectionApprovalOutcome.allCases)
    func connectionApprovalFinishesBeforeAnyTabOrConnectionPreparation(
        _ outcome: ConnectionApprovalOutcome
    ) async throws {
        let effects = TerminalEffectRecorder()
        let gate = TerminalAuthorizationGate()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: effects,
            remoteSessions: RecordingTerminalRemoteTmuxService(),
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "connection-approval"
        )
        let server = makeServer()
        let opening = Task {
            try await manager.openTab(for: server) { await gate.wait() }
        }
        #expect(await gate.waitUntilBlocked())
        #expect(effects.authorizationRequests == [server.id])
        #expect(manager.sessionState.tabs(for: server.id).isEmpty)
        #expect(effects.initialConnectionPreparations.isEmpty)

        if outcome == .cancelled { opening.cancel() }
        await gate.resolve(outcome != .denied)
        do {
            let tab = try await opening.value
            #expect(outcome == .approved)
            #expect(manager.sessionState.tabs(for: server.id) == [tab])
            #expect(effects.initialConnectionPreparations == [server.id])
        } catch is CancellationError {
            #expect(outcome != .approved)
            #expect(manager.sessionState.tabs(for: server.id).isEmpty)
            #expect(effects.initialConnectionPreparations.isEmpty)
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        await manager.resetForTesting()
    }

    @Test
    func serverAuthorizationDenialDoesNotStartConnectionApproval() async throws {
        let effects = TerminalEffectRecorder()
        effects.authorizeResult = false
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: effects,
            remoteSessions: RecordingTerminalRemoteTmuxService(),
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "server-authorization-denied"
        )
        let server = makeServer()
        var connectionApprovalStarted = false
        do {
            _ = try await manager.openTab(for: server) {
                connectionApprovalStarted = true
                return true
            }
            Issue.record("Server authorization must stop the tab open")
        } catch {
            #expect(error as? VVTermError == .authenticationFailed)
        }
        #expect(effects.authorizationRequests == [server.id])
        #expect(!connectionApprovalStarted)
        #expect(manager.sessionState.tabs(for: server.id).isEmpty)
        #expect(effects.initialConnectionPreparations.isEmpty)
        await manager.resetForTesting()
    }

    @Test(arguments: [false, true])
    func disconnectInvalidatesAuthorizedTabOpenBeforeItMutatesSessionState(
        waitingForConnectionApproval: Bool
    ) async throws {
        let effects = TerminalEffectRecorder()
        let gate = TerminalAuthorizationGate()
        if !waitingForConnectionApproval { effects.authorizationGate = gate }
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: effects,
            remoteSessions: RecordingTerminalRemoteTmuxService(),
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "tab-open-generation"
        )
        let server = makeServer()
        let staleOpen = Task {
            try await manager.openTab(for: server) {
                if waitingForConnectionApproval { return await gate.wait() }
                return true
            }
        }
        #expect(await gate.waitUntilBlocked())

        manager.disconnectServer(server.id)
        effects.authorizationGate = nil
        let replacement = try await manager.openTab(for: server)
        await gate.resolve(true)

        do {
            _ = try await staleOpen.value
            Issue.record("The stale authorized tab open should be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(manager.sessionState.tabs(for: server.id) == [replacement])
        await manager.resetForTesting()
    }

    @Test
    func disabledTmuxProducesPlainStartupPlanWithoutRemoteProbe() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            deviceID: "skip-device"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Skip tmux")
        install(tab, in: manager)
        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )

        let plan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: client,
            startToken: startToken
        )

        #expect(plan.command == nil)
        #expect(plan.remoteSessionLifecycle == nil)
        #expect(await remoteSessions.availabilityProbeCount() == 0)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: client,
            startToken: startToken
        )
        await manager.resetForTesting()
    }

    @Test
    func serverStartupActionReplacesPlainShellWithoutRemoteSessionProbe() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            startupAction: try RemoteShellStartupAction(
                command: "cd ~/myproject && printf '%s' \"$(date)\""
            ),
            deviceID: "custom-startup-device"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Custom startup")
        install(tab, in: manager)
        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )

        let plan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: client,
            startToken: startToken
        )

        #expect(plan.command == "cd ~/myproject && printf '%s' \"$(date)\"")
        #expect(plan.remoteSessionLifecycle == nil)
        #expect(plan.mayExecuteUserStartupAction)
        #expect(await remoteSessions.availabilityProbeCount() == 0)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: client,
            startToken: startToken
        )
        await manager.resetForTesting()
    }

    @Test
    func pendingStartupActionIsNotPlannedAgain() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            startupAction: try RemoteShellStartupAction(command: "notify-deployment"),
            deviceID: "pending-custom-startup-device"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Pending custom startup")
        install(tab, in: manager)
        manager.sessionState.updatePane(tab.rootPaneId) {
            $0.startupActionReplayPending = true
        }
        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )

        let plan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: client,
            startToken: startToken
        )

        #expect(plan.command == nil)
        #expect(!plan.mayExecuteUserStartupAction)
        #expect(await remoteSessions.availabilityProbeCount() == 0)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: client,
            startToken: startToken
        )
        await manager.resetForTesting()
    }

    @Test
    func persistentStartupCommandDoesNotRunWhenSessionCannotBeCreated() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            startupAction: try RemoteShellStartupAction(command: "touch /tmp/must-not-run"),
            remoteSessionEnabled: true,
            deviceID: "unavailable-persistent-session"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Unavailable persistence")
        install(tab, in: manager)
        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )

        let plan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: client,
            startToken: startToken
        )

        #expect(plan.command == nil)
        #expect(plan.remoteSessionLifecycle == nil)
        #expect(await remoteSessions.availabilityProbeCount() == 1)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: client,
            startToken: startToken
        )
        await manager.resetForTesting()
    }

    @Test
    func persistentSessionRejectsSavedSessionManagerCommandBeforeRemoteProbe() async throws {
        let remoteSessions = RecordingTerminalRemoteTmuxService()
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            startupAction: try RemoteShellStartupAction(command: "zmx attach main"),
            remoteSessionEnabled: true,
            deviceID: "conflicting-session-command"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Conflicting session command")
        install(tab, in: manager)
        let client = SSHClient.testing()
        let startToken = try #require(
            manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )

        do {
            _ = try await manager.remoteSessionCoordinator.startupPlan(
                for: tab.rootPaneId,
                serverID: tab.serverId,
                client: client,
                startToken: startToken
            )
            Issue.record("Expected a persistent-session startup command conflict")
        } catch SSHError.persistentSessionStartupCommandConflict {
            // Expected.
        } catch {
            Issue.record("Expected the conflict error, got \(error)")
        }

        #expect(await remoteSessions.availabilityProbeCount() == 0)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: client,
            startToken: startToken
        )
        await manager.resetForTesting()
    }

    @Test
    func persistentStartupCommandRunsForCreateButNotReconnect() async throws {
        let probe = RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(validating: "/usr/bin/tmux"),
            implementationVariant: "unix-tmux",
            rawVersion: "3.5",
            semanticVersion: RemoteSessionSemanticVersion("3.5"),
            shellFamily: .posix,
            shellExecutable: "/bin/sh"
        )
        let remoteSessions = RecordingTerminalRemoteTmuxService(
            availabilityResult: .available(probe)
        )
        let command = "cd ~/myproject && printf ready"
        let manager = makeManager(
            network: PassthroughSubject<TerminalNetworkReadiness, Never>(),
            effects: TerminalEffectRecorder(),
            remoteSessions: remoteSessions,
            remoteMosh: RecordingTerminalRemoteMoshService(),
            startupAction: try RemoteShellStartupAction(command: command),
            remoteSessionEnabled: true,
            startupBehavior: .createManaged,
            deviceID: "create-only-command"
        )
        let tab = TerminalTab(serverId: UUID(), title: "Create only")
        install(tab, in: manager)

        let firstClient = SSHClient.testing()
        let firstToken = try #require(
            manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: firstClient
            )
        )
        let createPlan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: firstClient,
            startToken: firstToken
        )
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: firstClient,
            startToken: firstToken
        )

        manager.remoteSessionCoordinator.confirmManagedSession(for: tab.rootPaneId)
        let reconnectClient = SSHClient.testing()
        let reconnectToken = try #require(
            manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: reconnectClient
            )
        )
        let reconnectPlan = try await manager.remoteSessionCoordinator.startupPlan(
            for: tab.rootPaneId,
            serverID: tab.serverId,
            client: reconnectClient,
            startToken: reconnectToken
        )

        let requests = await remoteSessions.launchRequests()
        #expect(requests.count == 2)
        let firstRequest = try #require(requests.first)
        let lastRequest = try #require(requests.last)
        if case .ensureManaged(_, let initialCommand) = firstRequest.intent {
            #expect(initialCommand == command)
        } else {
            Issue.record("Expected the first launch to ensure a managed session")
        }
        if case .attach(let attachment) = lastRequest.intent {
            #expect(attachment.ownership == .managed)
        } else {
            Issue.record("Expected reconnect to attach the existing managed session")
        }
        #expect(createPlan.mayExecuteUserStartupAction)
        #expect(reconnectPlan.command != nil)
        #expect(!reconnectPlan.mayExecuteUserStartupAction)
        manager.transportCoordinator.finishShellStart(
            for: tab.rootPaneId,
            client: reconnectClient,
            startToken: reconnectToken
        )
        await manager.resetForTesting()
    }

    @Test
    func independentManagersRouteEffectsAndRuntimeServicesOnlyToTheirOwners() async throws {
        let firstNetwork = PassthroughSubject<TerminalNetworkReadiness, Never>()
        let secondNetwork = PassthroughSubject<TerminalNetworkReadiness, Never>()
        let firstEffects = TerminalEffectRecorder()
        let secondEffects = TerminalEffectRecorder()
        let firstTmux = RecordingTerminalRemoteTmuxService()
        let secondTmux = RecordingTerminalRemoteTmuxService()
        let firstMosh = RecordingTerminalRemoteMoshService()
        let secondMosh = RecordingTerminalRemoteMoshService()
        let first = makeManager(
            network: firstNetwork,
            effects: firstEffects,
            remoteSessions: firstTmux,
            remoteMosh: firstMosh,
            deviceID: "first-device"
        )
        let second = makeManager(
            network: secondNetwork,
            effects: secondEffects,
            remoteSessions: secondTmux,
            remoteMosh: secondMosh,
            deviceID: "second-device"
        )

        firstNetwork.send(.ready)
        #expect(first.reconnectCoordinator.currentNetworkReadiness == .ready)
        #expect(second.reconnectCoordinator.currentNetworkReadiness == .unknown)

        firstEffects.authorizeResult = false
        do {
            _ = try await first.openTab(for: makeServer())
            Issue.record("The injected access denial should stop the tab open")
        } catch {
            #expect(firstEffects.authorizationRequests.count == 1)
        }
        #expect(first.sessionState.serverIdsWithTabs.isEmpty)
        #expect(secondEffects.authorizationRequests.isEmpty)

        let tab = TerminalTab(serverId: UUID(), title: "First manager")
        install(tab, in: first)
        #expect(first.splitRight(
            tab: tab,
            paneId: tab.rootPaneId,
            hasProAccess: true
        ) != nil)
        first.updatePaneState(tab.rootPaneId, connectionState: .connected)

        let client = SSHClient.testing()
        let startToken = try #require(
            first.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client)
        )
        #expect(await first.transportCoordinator.registerSSHClient(
            client,
            shellId: UUID(),
            startToken: startToken,
            for: tab.rootPaneId,
            serverId: tab.serverId
        ))
        first.remoteSessionCoordinator.setAttachment(
            for: tab.rootPaneId,
            identifier: try! RemoteSessionIdentifier(
                backendIdentifier: .tmux,
                validating: "first-session"
            ),
            ownership: .managed
        )

        try await first.transportCoordinator.installMoshServer(for: tab.rootPaneId)
        first.remoteSessionCoordinator.killIfNeeded(for: tab.rootPaneId)
        #expect(await waitUntil {
            await firstTmux.killedSessionIdentifiers().map(\.rawValue) == ["first-session"]
        })
        await first.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
        first.closeTab(tab)

        #expect(firstEffects.liveActivityRefreshCount > 1)
        #expect(firstEffects.successfulConnections.map(\.0) == [tab.rootPaneId])
        #expect(firstEffects.sessionEndStates == [false])
        #expect(firstEffects.splitPaneCount == 1)
        #expect(secondEffects.liveActivityRefreshCount == 1)
        #expect(secondEffects.successfulConnections.isEmpty)
        #expect(secondEffects.sessionEndStates.isEmpty)
        #expect(secondEffects.splitPaneCount == 0)
        #expect(await firstMosh.installCount() == 1)
        #expect(await secondMosh.installCount() == 0)
        #expect(await secondTmux.killedSessionIdentifiers().isEmpty)
        #expect(
            try! first.remoteSessionCoordinator.resolver.managedIdentifier(
                for: tab.rootPaneId,
                serverID: tab.serverId,
                backendIdentifier: .tmux
            ) != second.remoteSessionCoordinator.resolver.managedIdentifier(
                for: tab.rootPaneId,
                serverID: tab.serverId,
                backendIdentifier: .tmux
            )
        )

        await first.resetForTesting()
        await second.resetForTesting()
    }

    private func makeManager(
        network: PassthroughSubject<TerminalNetworkReadiness, Never>,
        effects: TerminalEffectRecorder,
        remoteSessions: any TerminalRemoteSessionServicing,
        remoteMosh: RecordingTerminalRemoteMoshService,
        startupAction: RemoteShellStartupAction? = nil,
        remoteSessionEnabled: Bool = false,
        startupBehavior: RemoteSessionStartupBehavior = .plainShell,
        deviceID: String
    ) -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: DependencyTestSnapshotStore(),
            dependencies: TerminalTabManagerDependencies(
                sshClientFactory: .testing(),
                networkReadiness: TerminalNetworkReadinessSource(
                    initial: .unknown,
                    updates: network.eraseToAnyPublisher()
                ),
                applicationIsActive: { true },
                appLock: TerminalAppLockSource(
                    initialIsLocked: false,
                    updates: Empty<Bool, Never>().eraseToAnyPublisher()
                ),
                effects: effects.effects(),
                remoteMosh: remoteMosh,
                eternalTerminalRuntime: .testing
            ),
            remoteSessionConfiguration: TerminalRemoteSessionConfiguration(
                deviceID: deviceID,
                enabledByDefault: { remoteSessionEnabled },
                backendIdentifierByDefault: { .tmux },
                startupBehaviorByDefault: { startupBehavior },
                serverSettings: { _ in
                    TerminalRemoteSessionConfiguration.ServerSettings(
                        name: "Test Server",
                        enabledOverride: remoteSessionEnabled,
                        backendIdentifier: .tmux,
                        startupBehaviorOverride: startupBehavior,
                        startupAction: startupAction
                    )
                },
                themeStyle: { TerminalRemoteSessionLiveComposition.themeStyle(for: nil) }
            ),
            remoteSessions: remoteSessions,
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            eternalTerminalResumeStore: DependencyTestETResumeStore(),
            moshRecovery: UnavailableTerminalMoshRecoveryService()
        )
    }

    private func install(_ tab: TerminalTab, in manager: TerminalTabManager) {
        manager.sessionState.install(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ), select: true)
        manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Denied",
            host: "example.invalid",
            username: "test"
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}
