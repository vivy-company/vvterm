import Foundation
import Combine
import Testing
@testable import VVTerm

@MainActor
private final class StateStoreSnapshotMemory: TerminalTabSnapshotStoring {
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

@Suite
@MainActor
struct TerminalSessionStateStoreTests {
    @Test
    func independentStoresDoNotShareTabsPanesSelectionsOrPersistence() {
        let firstSnapshot = StateStoreSnapshotMemory()
        let secondSnapshot = StateStoreSnapshotMemory()
        let firstSelections = ConnectionViewSelectionStore()
        let secondSelections = ConnectionViewSelectionStore()
        let first = makeStore(snapshot: firstSnapshot, selections: firstSelections)
        let second = makeStore(snapshot: secondSnapshot, selections: secondSelections)
        let tab = TerminalTab(serverId: UUID(), title: "First")
        var pane = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
        pane.connectionState = .connected

        first.install(tab, paneState: pane, select: true)
        first.selectView(.files, for: tab.serverId)
        first.persistNow()

        #expect(first.tabs(for: tab.serverId) == [tab])
        #expect(first.paneState(for: tab.rootPaneId)?.connectionState == .connected)
        #expect(firstSelections.selection(for: tab.serverId) == .files)
        #expect(firstSnapshot.data != nil)

        #expect(second.tabs(for: tab.serverId).isEmpty)
        #expect(second.paneState(for: tab.rootPaneId) == nil)
        #expect(secondSelections.selection(for: tab.serverId) == nil)
        #expect(secondSnapshot.data == nil)
    }

    @Test
    func snapshotRestoresTabPaneAndNormalizesStaleSelection() throws {
        let snapshot = StateStoreSnapshotMemory()
        let sourceSelections = ConnectionViewSelectionStore()
        let source = makeStore(snapshot: snapshot, selections: sourceSelections)
        let tab = TerminalTab(serverId: UUID(), title: "Restored")
        let staleSelectedTabId = UUID()
        var pane = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
        pane.presentationOverrides = TerminalPresentationOverrides(fontSize: 18)
        pane.disconnectReason = .transportEnded

        source.install(tab, paneState: pane, select: true)
        source.selectTab(staleSelectedTabId, for: tab.serverId)
        source.selectView(.stats, for: tab.serverId)
        source.persistNow()

        let restoredSelections = ConnectionViewSelectionStore()
        let restored = makeStore(snapshot: snapshot, selections: restoredSelections)

        #expect(restored.tabs(for: tab.serverId) == [tab])
        #expect(restored.selectedTabId(for: tab.serverId) == tab.id)
        #expect(restored.selectedTab(for: tab.serverId) == tab)
        #expect(restoredSelections.selection(for: tab.serverId) == .stats)
        #expect(restored.paneState(for: tab.rootPaneId)?.presentationOverrides.fontSize == 18)
        #expect(restored.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
        #expect(restored.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
    }

    @Test
    func closingSelectedTabSelectsTheNearestRemainingTab() {
        let store = makeStore(
            snapshot: StateStoreSnapshotMemory(),
            selections: ConnectionViewSelectionStore()
        )
        let serverId = UUID()
        let first = TerminalTab(serverId: serverId, title: "First")
        let second = TerminalTab(serverId: serverId, title: "Second")
        let third = TerminalTab(serverId: serverId, title: "Third")
        for tab in [first, second, third] {
            store.install(
                tab,
                paneState: TerminalPaneState(
                    paneId: tab.rootPaneId,
                    tabId: tab.id,
                    serverId: serverId
                ),
                select: true
            )
        }
        store.selectTab(second.id, for: serverId)

        store.removeTab(second)

        #expect(store.tabs(for: serverId) == [first, third])
        #expect(store.selectedTabId(for: serverId) == third.id)
        #expect(store.paneState(for: second.rootPaneId) == nil)
    }

    @Test
    func removingSplitPaneReturnsAndRemovesItsDescriptor() {
        let store = makeStore(
            snapshot: StateStoreSnapshotMemory(),
            selections: ConnectionViewSelectionStore()
        )
        let tab = TerminalTab(serverId: UUID(), title: "Split")
        store.install(
            tab,
            paneState: TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ),
            select: true
        )
        guard let splitPaneId = store.createSplitPane(
            in: tab,
            paneId: tab.rootPaneId,
            placement: .right,
            tmuxStatus: .off
        ), let splitTab = store.tab(id: tab.id, for: tab.serverId) else {
            Issue.record("Expected split pane")
            return
        }

        guard case .removed(let removedPaneId, let paneState, let updatedTab) = store.removePane(
            in: splitTab,
            paneId: splitPaneId
        ) else {
            Issue.record("Expected split pane removal")
            return
        }

        #expect(removedPaneId == splitPaneId)
        #expect(paneState?.paneId == splitPaneId)
        #expect(store.paneState(for: splitPaneId) == nil)
        #expect(updatedTab.allPaneIds == [tab.rootPaneId])
    }

    @Test
    func nonFiniteSplitRatioCannotReplaceValidLayout() throws {
        let store = makeStore(
            snapshot: StateStoreSnapshotMemory(),
            selections: ConnectionViewSelectionStore()
        )
        let tab = TerminalTab(serverId: UUID(), title: "Split")
        store.install(
            tab,
            paneState: TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ),
            select: true
        )
        let splitPaneId = try #require(store.createSplitPane(
            in: tab,
            paneId: tab.rootPaneId,
            placement: .right,
            tmuxStatus: .off
        ))
        let splitTab = try #require(store.tab(id: tab.id, for: tab.serverId))
        let layout = try #require(splitTab.layout)

        #expect(store.updateSplitRatio(
            in: splitTab,
            node: layout,
            ratio: .infinity
        ) == nil)
        #expect(store.updateSplitRatio(
            in: splitTab,
            node: layout,
            ratio: .nan
        ) == nil)
        #expect(store.tab(id: tab.id, for: tab.serverId)?.layout == layout)
        #expect(store.paneState(for: splitPaneId) != nil)
    }

    @Test
    func serverSnapshotPublisherIgnoresOtherServersAndWorkingDirectoryChurn() {
        let selections = ConnectionViewSelectionStore()
        let store = makeStore(
            snapshot: StateStoreSnapshotMemory(),
            selections: selections
        )
        let observedServerId = UUID()
        let otherServerId = UUID()
        var updateCount = 0
        let cancellation = store.changes(for: observedServerId).dropFirst().sink { _ in
            updateCount += 1
        }
        defer { cancellation.cancel() }

        let otherTab = TerminalTab(serverId: otherServerId, title: "Other")
        store.install(
            otherTab,
            paneState: TerminalPaneState(
                paneId: otherTab.rootPaneId,
                tabId: otherTab.id,
                serverId: otherServerId
            ),
            select: true
        )
        selections.setSelection(.files, for: otherServerId)

        #expect(updateCount == 0)

        let observedTab = TerminalTab(serverId: observedServerId, title: "Observed")
        store.install(
            observedTab,
            paneState: TerminalPaneState(
                paneId: observedTab.rootPaneId,
                tabId: observedTab.id,
                serverId: observedServerId
            ),
            select: true
        )

        #expect(updateCount > 0)
        let relevantUpdateCount = updateCount

        store.updatePane(otherTab.rootPaneId) { state in
            state.connectionState = .connected
        }
        store.updatePane(observedTab.rootPaneId) { state in
            state.workingDirectory = "/tmp/output-driven-update"
        }
        selections.setSelection(.stats, for: otherServerId)

        #expect(updateCount == relevantUpdateCount)

        store.updatePane(observedTab.rootPaneId) { state in
            state.connectionState = .connected
        }

        #expect(updateCount == relevantUpdateCount + 1)
    }

    @Test
    func noOpPaneMutationDoesNotPublish() {
        let store = makeStore(
            snapshot: StateStoreSnapshotMemory(),
            selections: ConnectionViewSelectionStore()
        )
        let tab = TerminalTab(serverId: UUID(), title: "Stable")
        let pane = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
        store.install(tab, paneState: pane, select: true)
        var updateCount = 0
        let cancellation = store.objectWillChange.sink {
            updateCount += 1
        }
        defer { cancellation.cancel() }

        let didChange = store.updatePane(tab.rootPaneId) { state in
            state.workingDirectory = state.workingDirectory
        }
        store.setPaneState(pane)

        #expect(didChange == false)
        #expect(updateCount == 0)
    }

    private func makeStore(
        snapshot: StateStoreSnapshotMemory,
        selections: ConnectionViewSelectionStore
    ) -> TerminalSessionStateStore {
        let configuration = TerminalTmuxConfiguration.testing
        let remoteTmux = UnavailableTerminalRemoteTmuxService()
        return TerminalSessionStateStore(
            snapshotStore: snapshot,
            connectionViewSelections: selections,
            tmuxResolver: TmuxAttachResolver(
                configuration: configuration,
                remoteTmux: remoteTmux
            )
        )
    }
}
