import CoreGraphics
import ETSession
import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class InMemoryTerminalTabSnapshotStore: TerminalTabSnapshotStoring {
    private(set) var data: Data?

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

private final class IsolatedEternalTerminalResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? { nil }
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? { nil }
    func hasCheckpoint(for paneId: UUID) -> Bool { false }
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {}
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {}
    func deleteResumeState(for paneId: UUID) throws {}
}

private actor TerminalOwnerReleaseCancellationProbe {
    private var didStart = false
    private var didObserveCancellation = false

    func run() async {
        didStart = true
        while !Task.isCancelled {
            await Task.yield()
        }
        didObserveCancellation = true
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<2_000 {
            if didStart { return true }
            await Task.yield()
        }
        return didStart
    }

    func waitUntilCancelled() async -> Bool {
        for _ in 0..<2_000 {
            if didObserveCancellation { return true }
            await Task.yield()
        }
        return didObserveCancellation
    }
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerIndependenceTests {
    @Test
    func richPasteRuntimeSurvivesPaneViewReconstructionAndClosesWithPane() {
        let manager = makeManager(snapshotStore: InMemoryTerminalTabSnapshotStore())
        let tab = TerminalTab(serverId: UUID(), title: "Rich Paste")
        install(tab, in: manager)

        let firstRuntime = manager.richPasteRuntimeStore.runtime(
            for: tab.rootPaneId,
            tabManager: manager
        )
        let reconstructedPaneRuntime = manager.richPasteRuntimeStore.runtime(
            for: tab.rootPaneId,
            tabManager: manager
        )

        #expect(firstRuntime === reconstructedPaneRuntime)
        #expect(manager.richPasteRuntimeStore.runtimeCount == 1)

        manager.closeTab(tab)

        #expect(manager.richPasteRuntimeStore.runtimeCount == 0)
    }

    @Test
    func ownerReleaseCancelsConnectionWorkWithoutRetainingManagerOrTransportOwner() async {
        var manager: TerminalTabManager? = makeManager(
            snapshotStore: InMemoryTerminalTabSnapshotStore()
        )
        let tab = TerminalTab(serverId: UUID(), title: "Owner release")
        install(tab, in: manager!)
        let probe = TerminalOwnerReleaseCancellationProbe()

        #expect(manager?.transportCoordinator.startSSHConnectionTask(
            for: tab.rootPaneId,
            server: Server(
                id: tab.serverId,
                workspaceId: UUID(),
                name: "Owner release",
                host: "example.com",
                username: "tester"
            ),
            client: SSHClient.testing(),
            operation: { _ in await probe.run() }
        ) == true)
        #expect(await probe.waitUntilStarted())

        weak let releasedManager = manager
        weak let releasedTransportOwner = manager?.transportCoordinator
        weak let releasedTmuxOwner = manager?.tmuxCoordinator
        weak let releasedSessionState = manager?.sessionState
        manager = nil

        #expect(releasedManager == nil)
        #expect(releasedTransportOwner == nil)
        #expect(releasedTmuxOwner == nil)
        #expect(releasedSessionState == nil)
        #expect(await probe.waitUntilCancelled())
    }

    @Test
    func managersDoNotSharePaneShellTmuxOrTerminalRegistrations() async throws {
        let first = makeManager(snapshotStore: InMemoryTerminalTabSnapshotStore())
        let second = makeManager(snapshotStore: InMemoryTerminalTabSnapshotStore())
        let tab = TerminalTab(serverId: UUID(), title: "Independent runtime")
        install(tab, in: first)
        install(tab, in: second)

        let ghosttyApp = GhosttyRuntime()
        let appHandle = try #require(ghosttyApp.app)
        let terminal: GhosttyTerminalView
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: ghosttyApp,
            paneId: tab.rootPaneId.uuidString,
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "independence-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: ghosttyApp,
            paneId: tab.rootPaneId.uuidString,
            useCustomIO: true
        )
        #endif
        defer {
            first.unregisterTerminalSurface(terminal, for: tab.rootPaneId)
            ghosttyApp.cleanup()
        }

        first.updatePaneState(tab.rootPaneId, connectionState: .connected)
        let client = SSHClient.testing()
        let startToken = try #require(first.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: client))
        #expect(await first.transportCoordinator.registerSSHClient(
            client,
            shellId: UUID(),
            startToken: startToken,
            for: tab.rootPaneId,
            serverId: tab.serverId
        ))
        first.tmuxCoordinator.setAttachment(
            for: tab.rootPaneId,
            sessionName: "vvterm-isolated",
            ownership: .managed
        )
        first.registerTerminalSurface(terminal, for: tab.rootPaneId)

        #expect(first.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .connected)
        #expect(second.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
        #expect(first.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.client === client)
        #expect(second.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)
        #expect(first.tmuxCoordinator.attachment(for: tab.rootPaneId)?.sessionName == "vvterm-isolated")
        #expect(second.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
        #expect(
            first.terminalSurfaceStore.surface(for: tab.rootPaneId) === terminal
        )
        #expect(second.terminalSurfaceStore.surface(for: tab.rootPaneId) == nil)

        await first.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
    }

    @Test
    func separateStoresRestoreOnlyTheirOwnSelectedState() {
        let firstStore = InMemoryTerminalTabSnapshotStore()
        let secondStore = InMemoryTerminalTabSnapshotStore()
        let first = makeManager(snapshotStore: firstStore)
        let second = makeManager(snapshotStore: secondStore)
        let serverId = UUID()
        let firstTab = TerminalTab(serverId: serverId, title: "First")
        let secondTab = TerminalTab(serverId: serverId, title: "Second")

        install(firstTab, in: first)
        first.sessionState.selectView(.files, for: serverId)
        first.tmuxCoordinator.setAttachment(
            for: firstTab.rootPaneId,
            sessionName: "first-session",
            ownership: .managed
        )

        install(secondTab, in: second)
        second.sessionState.selectView(.stats, for: serverId)

        first.sessionState.persistAndRestoreSnapshotForTesting()
        second.sessionState.persistAndRestoreSnapshotForTesting()

        let restoredFirst = makeManager(snapshotStore: firstStore)
        let restoredSecond = makeManager(snapshotStore: secondStore)

        #expect(restoredFirst.sessionState.selectedTabId(for: serverId) == firstTab.id)
        #expect(restoredFirst.connectionViewSelections.selection(for: serverId) == .files)
        #expect(restoredFirst.sessionState.paneState(for: firstTab.rootPaneId) != nil)
        #expect(restoredFirst.sessionState.paneState(for: secondTab.rootPaneId) == nil)
        #expect(restoredFirst.tmuxCoordinator.attachment(for: firstTab.rootPaneId)?.sessionName == "first-session")

        #expect(restoredSecond.sessionState.selectedTabId(for: serverId) == secondTab.id)
        #expect(restoredSecond.connectionViewSelections.selection(for: serverId) == .stats)
        #expect(restoredSecond.sessionState.paneState(for: secondTab.rootPaneId) != nil)
        #expect(restoredSecond.sessionState.paneState(for: firstTab.rootPaneId) == nil)
        #expect(restoredSecond.tmuxCoordinator.attachment(for: firstTab.rootPaneId) == nil)
    }

    private func makeManager(
        snapshotStore: InMemoryTerminalTabSnapshotStore
    ) -> TerminalTabManager {
        TerminalTabManager(
            snapshotStore: snapshotStore,
            networkReadinessPublisher: nil,
            liveActivityRefresh: { _ in },
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            eternalTerminalResumeStore: IsolatedEternalTerminalResumeStore(),
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
}
