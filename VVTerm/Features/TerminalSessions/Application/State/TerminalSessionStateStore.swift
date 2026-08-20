import Combine
import Foundation
import os.log

@MainActor
enum TerminalSessionPaneRemoval {
    case closeTab(TerminalTab)
    case removed(
        paneId: UUID,
        paneState: TerminalPaneState?,
        updatedTab: TerminalTab
    )
}

/// Owns the durable terminal tab graph and its pane state.
@MainActor
final class TerminalSessionStateStore: ObservableObject {
    @Published private var tabsByServer: [UUID: [TerminalTab]] = [:] {
        didSet { schedulePersist() }
    }
    @Published private var selectedTabByServer: [UUID: UUID] = [:] {
        didSet { schedulePersist() }
    }
    @Published private var paneStates: [UUID: TerminalPaneState] = [:]

    private let snapshotStore: any TerminalTabSnapshotStoring
    private let connectionViewSelections: ConnectionViewSelectionStore
    private let tmuxResolver: TmuxAttachResolver
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "TerminalSessionStateStore"
    )
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    init(
        snapshotStore: any TerminalTabSnapshotStoring,
        connectionViewSelections: ConnectionViewSelectionStore,
        tmuxResolver: TmuxAttachResolver
    ) {
        self.snapshotStore = snapshotStore
        self.connectionViewSelections = connectionViewSelections
        self.tmuxResolver = tmuxResolver
        restoreSnapshot()
    }

    var serverIdsWithTabs: Set<UUID> {
        Set(tabsByServer.compactMap { serverId, tabs in
            tabs.isEmpty ? nil : serverId
        })
    }

    var selectedTabChanges: AnyPublisher<[UUID: UUID], Never> {
        $selectedTabByServer
            .eraseToAnyPublisher()
    }

    var paneConnectionStateChanges: AnyPublisher<[ConnectionState], Never> {
        $paneStates
            .map { $0.values.map(\.connectionState) }
            .eraseToAnyPublisher()
    }

    var navigationChanges: AnyPublisher<TerminalSessionNavigationState, Never> {
        Publishers.CombineLatest($tabsByServer, $paneStates)
            .map(Self.makeNavigationState)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var navigationState: TerminalSessionNavigationState {
        Self.makeNavigationState(tabsByServer: tabsByServer, paneStates: paneStates)
    }

    private static func makeNavigationState(
        tabsByServer: [UUID: [TerminalTab]],
        paneStates: [UUID: TerminalPaneState]
    ) -> TerminalSessionNavigationState {
        TerminalSessionNavigationState(
            tabCountsByServer: tabsByServer.reduce(into: [:]) { result, element in
                guard !element.value.isEmpty else { return }
                result[element.key] = element.value.count
            },
            connectedServerIds: Set(paneStates.values.compactMap { state in
                state.connectionState.isConnected ? state.serverId : nil
            })
        )
    }

    func changes(for serverId: UUID) -> AnyPublisher<TerminalServerSessionSnapshot, Never> {
        Publishers.CombineLatest3($tabsByServer, $selectedTabByServer, $paneStates)
            .map { tabsByServer, selectedTabByServer, paneStates in
                Self.makeServerSnapshot(
                    serverId: serverId,
                    tabsByServer: tabsByServer,
                    selectedTabByServer: selectedTabByServer,
                    paneStates: paneStates
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func presentationChanges(for paneId: UUID) -> AnyPublisher<TerminalPanePresentationState?, Never> {
        $paneStates
            .map { $0[paneId].map(TerminalPanePresentationState.init) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func presentationState(for paneId: UUID) -> TerminalPanePresentationState? {
        paneStates[paneId].map(TerminalPanePresentationState.init)
    }

    func snapshot(for serverId: UUID) -> TerminalServerSessionSnapshot {
        Self.makeServerSnapshot(
            serverId: serverId,
            tabsByServer: tabsByServer,
            selectedTabByServer: selectedTabByServer,
            paneStates: paneStates
        )
    }

    private static func makeServerSnapshot(
        serverId: UUID,
        tabsByServer: [UUID: [TerminalTab]],
        selectedTabByServer: [UUID: UUID],
        paneStates: [UUID: TerminalPaneState]
    ) -> TerminalServerSessionSnapshot {
        TerminalServerSessionSnapshot(
            tabs: tabsByServer[serverId] ?? [],
            selectedTabId: selectedTabByServer[serverId],
            connectionStatesByPane: paneStates.reduce(into: [:]) { result, element in
                guard element.value.serverId == serverId else { return }
                result[element.key] = element.value.connectionState
            }
        )
    }

    var paneIds: Set<UUID> {
        Set(paneStates.keys)
    }

    var allPaneStates: [TerminalPaneState] {
        Array(paneStates.values)
    }

    var connectionStates: [ConnectionState] {
        paneStates.values.map(\.connectionState)
    }

    var hasConnectedPanes: Bool {
        paneStates.values.contains { $0.connectionState.isConnected }
    }

    func tabs(for serverId: UUID) -> [TerminalTab] {
        tabsByServer[serverId] ?? []
    }

    func tab(id tabId: UUID, for serverId: UUID) -> TerminalTab? {
        tabs(for: serverId).first { $0.id == tabId }
    }

    func selectedTabId(for serverId: UUID) -> UUID? {
        selectedTabByServer[serverId]
    }

    func selectedTab(for serverId: UUID) -> TerminalTab? {
        guard let tabId = selectedTabId(for: serverId) else {
            return tabs(for: serverId).first
        }
        return tab(id: tabId, for: serverId)
    }

    func paneState(for paneId: UUID) -> TerminalPaneState? {
        paneStates[paneId]
    }

    func presentationOverrides(for paneId: UUID) -> TerminalPresentationOverrides {
        paneStates[paneId]?.presentationOverrides ?? .empty
    }

    func containsPane(_ paneId: UUID) -> Bool {
        paneStates[paneId] != nil
    }

    func paneStates(for paneIds: [UUID]) -> [TerminalPaneState] {
        paneIds.compactMap { paneStates[$0] }
    }

    func paneStates(forServer serverId: UUID) -> [TerminalPaneState] {
        paneStates.values.filter { $0.serverId == serverId }
    }

    func firstPaneState(for serverId: UUID) -> TerminalPaneState? {
        paneStates.values.first { $0.serverId == serverId }
    }

    func canOpenNewTab(hasProAccess: Bool) -> Bool {
        hasProAccess || tabsByServer.values.lazy.flatMap { $0 }.count < FreeTierLimits.maxTabs
    }

    @discardableResult
    func createTab(
        serverId: UUID,
        title: String,
        sourcePaneId: UUID?,
        sourceWorkingDirectory: String?,
        tmuxStatus: TmuxStatus
    ) -> TerminalTab {
        let tab = TerminalTab(serverId: serverId, title: title)
        var paneState = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: serverId
        )
        paneState.workingDirectory = sourceWorkingDirectory
        paneState.seedPaneId = sourcePaneId
        paneState.tmuxStatus = tmuxStatus
        install(tab, paneState: paneState, select: true)
        return tab
    }

    func install(
        _ tab: TerminalTab,
        paneState: TerminalPaneState,
        select: Bool
    ) {
        paneStates[paneState.paneId] = paneState
        var serverTabs = tabsByServer[tab.serverId] ?? []
        if let index = serverTabs.firstIndex(where: { $0.id == tab.id }) {
            serverTabs[index] = tab
        } else {
            serverTabs.append(tab)
        }
        tabsByServer[tab.serverId] = serverTabs
        if select {
            selectedTabByServer[tab.serverId] = tab.id
        }
    }

    func selectTab(_ tabId: UUID?, for serverId: UUID) {
        guard selectedTabByServer[serverId] != tabId else { return }
        if let tabId {
            selectedTabByServer[serverId] = tabId
        } else {
            selectedTabByServer.removeValue(forKey: serverId)
        }
    }

    func selectView(_ selection: ConnectionViewTabID?, for serverId: UUID) {
        guard connectionViewSelections.selection(for: serverId) != selection else { return }
        connectionViewSelections.setSelection(selection, for: serverId)
        schedulePersist()
    }

    @discardableResult
    func removeTab(_ tab: TerminalTab) -> TerminalTab? {
        guard let currentTab = self.tab(id: tab.id, for: tab.serverId),
              var serverTabs = tabsByServer[currentTab.serverId],
              let closingIndex = serverTabs.firstIndex(where: { $0.id == currentTab.id }) else {
            return nil
        }

        for paneId in currentTab.allPaneIds {
            paneStates.removeValue(forKey: paneId)
        }
        serverTabs.remove(at: closingIndex)

        if serverTabs.isEmpty {
            tabsByServer.removeValue(forKey: currentTab.serverId)
            selectedTabByServer.removeValue(forKey: currentTab.serverId)
        } else {
            tabsByServer[currentTab.serverId] = serverTabs
            if selectedTabByServer[currentTab.serverId] == currentTab.id {
                selectedTabByServer[currentTab.serverId] = serverTabs[
                    min(closingIndex, serverTabs.count - 1)
                ].id
            }
        }
        return currentTab
    }

    func removeServer(_ serverId: UUID) {
        for tab in tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                paneStates.removeValue(forKey: paneId)
            }
        }
        tabsByServer.removeValue(forKey: serverId)
        selectedTabByServer.removeValue(forKey: serverId)
    }

    @discardableResult
    func createSplitPane(
        in tab: TerminalTab,
        paneId: UUID,
        placement: TerminalSplitPlacement,
        tmuxStatus: TmuxStatus
    ) -> UUID? {
        guard let currentTab = self.tab(id: tab.id, for: tab.serverId) else { return nil }

        let paneExists = currentTab.layout?.findPane(paneId)
            ?? (currentTab.rootPaneId == paneId)
        guard paneExists else { return nil }

        let newPaneId = UUID()
        var newState = TerminalPaneState(
            paneId: newPaneId,
            tabId: currentTab.id,
            serverId: currentTab.serverId
        )
        newState.workingDirectory = paneState(for: paneId)?.workingDirectory
        newState.seedPaneId = paneId
        newState.tmuxStatus = tmuxStatus
        paneStates[newPaneId] = newState

        let sourceNode = TerminalSplitNode.leaf(paneId: paneId)
        let newNode = TerminalSplitNode.leaf(paneId: newPaneId)
        let newSplit = TerminalSplitNode.split(.init(
            direction: placement.direction,
            ratio: 0.5,
            left: placement.insertsBeforeSource ? newNode : sourceNode,
            right: placement.insertsBeforeSource ? sourceNode : newNode
        ))

        var updatedTab = currentTab
        updatedTab.layout = currentTab.layout?
            .replacingPane(paneId, with: newSplit)
            .equalized() ?? newSplit
        updatedTab.focusedPaneId = newPaneId
        replaceTab(updatedTab)
        return newPaneId
    }

    func removePane(in tab: TerminalTab, paneId: UUID) -> TerminalSessionPaneRemoval? {
        guard let currentTab = self.tab(id: tab.id, for: tab.serverId) else { return nil }
        let paneExists = currentTab.layout?.findPane(paneId)
            ?? (currentTab.rootPaneId == paneId)
        guard paneExists else { return nil }

        guard currentTab.paneCount > 1 else {
            return .closeTab(currentTab)
        }
        guard let currentLayout = currentTab.layout,
              let newLayout = currentLayout.removingPane(paneId) else { return nil }

        var updatedTab = currentTab
        updatedTab.layout = newLayout.equalized()
        if updatedTab.focusedPaneId == paneId {
            let oldPanes = currentLayout.allPaneIds()
            let newPanes = newLayout.allPaneIds()
            if let closedIndex = oldPanes.firstIndex(of: paneId), !newPanes.isEmpty {
                updatedTab.focusedPaneId = newPanes[min(closedIndex, newPanes.count - 1)]
            } else {
                updatedTab.focusedPaneId = newPanes.first ?? currentTab.rootPaneId
            }
        }
        replaceTab(updatedTab)
        return .removed(
            paneId: paneId,
            paneState: paneStates.removeValue(forKey: paneId),
            updatedTab: updatedTab
        )
    }

    @discardableResult
    func replaceTab(_ tab: TerminalTab) -> Bool {
        guard var serverTabs = tabsByServer[tab.serverId],
              let index = serverTabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        serverTabs[index] = tab
        tabsByServer[tab.serverId] = serverTabs
        return true
    }

    @discardableResult
    func focusPane(in tab: TerminalTab, paneId: UUID) -> TerminalTab? {
        guard var currentTab = self.tab(id: tab.id, for: tab.serverId),
              currentTab.allPaneIds.contains(paneId),
              currentTab.focusedPaneId != paneId else { return nil }
        currentTab.focusedPaneId = paneId
        replaceTab(currentTab)
        return currentTab
    }

    @discardableResult
    func updateSplitRatio(
        in tab: TerminalTab,
        node: TerminalSplitNode,
        ratio: Double
    ) -> TerminalTab? {
        guard ratio.isFinite,
              var currentTab = self.tab(id: tab.id, for: tab.serverId),
              let currentLayout = currentTab.layout else { return nil }
        currentTab.layout = currentLayout.replacingNode(
            node,
            with: node.withUpdatedRatio(ratio)
        )
        replaceTab(currentTab)
        return currentTab
    }

    @discardableResult
    func equalizeSplitLayout(in tab: TerminalTab) -> TerminalTab? {
        guard var currentTab = self.tab(id: tab.id, for: tab.serverId),
              let currentLayout = currentTab.layout else { return nil }
        currentTab.layout = currentLayout.equalized()
        replaceTab(currentTab)
        return currentTab
    }

    @discardableResult
    func selectAdjacentPane(
        in tab: TerminalTab,
        paneId: UUID
    ) -> TerminalTab? {
        guard var currentTab = self.tab(id: tab.id, for: tab.serverId),
              currentTab.allPaneIds.contains(paneId) else { return nil }
        currentTab.focusedPaneId = paneId
        replaceTab(currentTab)
        return currentTab
    }

    @discardableResult
    func moveDivider(
        in tab: TerminalTab,
        direction: TerminalSplitResizeDirection
    ) -> TerminalTab? {
        guard var currentTab = self.tab(id: tab.id, for: tab.serverId),
              let layout = currentTab.layout,
              let updatedLayout = layout.movingDivider(
                  near: currentTab.focusedPaneId,
                  direction: direction
              ) else { return nil }
        currentTab.layout = updatedLayout
        replaceTab(currentTab)
        return currentTab
    }

    func setPaneState(_ paneState: TerminalPaneState) {
        guard paneStates[paneState.paneId] != paneState else { return }
        paneStates[paneState.paneId] = paneState
    }

    @discardableResult
    func updatePane(
        _ paneId: UUID,
        persist: Bool = false,
        _ mutation: (inout TerminalPaneState) -> Void
    ) -> Bool {
        guard var paneState = paneStates[paneId] else { return false }
        let previousState = paneState
        mutation(&paneState)
        guard paneState != previousState else { return false }
        paneStates[paneId] = paneState
        if persist {
            schedulePersist()
        }
        return true
    }

    func requestPersistence() {
        schedulePersist()
    }

    func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        persistSnapshot()
    }

    func prepareForApplicationTermination() -> Set<UUID> {
        persistTask?.cancel()
        persistTask = nil
        persistSnapshot()
        let ids = paneIds
        for paneId in ids {
            updatePane(paneId) { state in
                state.disconnectReason = .transportEnded
                state.connectionState = .disconnected
            }
        }
        return ids
    }

    private func makeServerSnapshots() -> [TerminalTabsSnapshot.ServerSnapshot] {
        tabsByServer.compactMap { serverId, tabs in
            guard !tabs.isEmpty else { return nil }
            return TerminalTabsSnapshot.ServerSnapshot(
                serverId: serverId,
                tabs: tabs.map {
                    TerminalTabsSnapshot.TabSnapshot(
                        from: $0,
                        paneStates: paneStates,
                        tmuxResolver: tmuxResolver
                    )
                },
                selectedTabId: selectedTabByServer[serverId],
                selectedView: connectionViewSelections.selection(for: serverId)?.rawValue
            )
        }
    }

    private func makeSnapshot() -> TerminalTabsSnapshot {
        TerminalTabsSnapshot(servers: makeServerSnapshots())
    }

    private func makeRestoredPaneStates(
        from tabsByServer: [UUID: [TerminalTab]],
        snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot]
    ) -> [UUID: TerminalPaneState] {
        var restoredPaneStates: [UUID: TerminalPaneState] = [:]
        for tabs in tabsByServer.values {
            for tab in tabs {
                for paneId in tab.allPaneIds {
                    var paneState = TerminalPaneState(
                        paneId: paneId,
                        tabId: tab.id,
                        serverId: tab.serverId
                    )
                    paneState.connectionState = .disconnected
                    paneState.markConnectionEstablished()
                    if !tmuxResolver.isTmuxEnabled(for: tab.serverId) {
                        paneState.tmuxStatus = .off
                    }
                    paneState.presentationOverrides = snapshotsByTabId[tab.id]?
                        .panePresentationOverrides?[paneId] ?? .empty
                    paneState.disconnectReason = snapshotsByTabId[tab.id]?
                        .paneDisconnectReasons?[paneId]
                    paneState.eternalTerminalTmuxResumeContext = snapshotsByTabId[tab.id]?
                        .eternalTerminalTmuxResumeContexts?[paneId]
                    restoredPaneStates[paneId] = paneState
                }
            }
        }
        return restoredPaneStates
    }

    private func applyRestoredSnapshot(_ snapshot: TerminalTabsSnapshot) {
        var restoredTabsByServer: [UUID: [TerminalTab]] = [:]
        var restoredSelectedTabs: [UUID: UUID] = [:]
        var restoredSelectedViews: [UUID: ConnectionViewTabID] = [:]
        var snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot] = [:]

        for server in snapshot.servers {
            for tabSnapshot in server.tabs {
                snapshotsByTabId[tabSnapshot.id] = tabSnapshot
            }
            let tabs = server.tabs.map { $0.toTerminalTab() }
            guard !tabs.isEmpty else { continue }
            restoredTabsByServer[server.serverId] = tabs
            let selected = server.selectedTabId.flatMap { selectedTabId in
                tabs.contains { $0.id == selectedTabId } ? selectedTabId : nil
            } ?? tabs[0].id
            restoredSelectedTabs[server.serverId] = selected
            if let view = server.selectedView.flatMap(ConnectionViewTabID.init(rawValue:)) {
                restoredSelectedViews[server.serverId] = view
            }
        }

        tabsByServer = restoredTabsByServer
        selectedTabByServer = restoredSelectedTabs
        connectionViewSelections.restore(restoredSelectedViews)
        var restoredAttachments: [UUID: TerminalTmuxAttachmentState] = [:]
        for tabSnapshot in snapshotsByTabId.values {
            for (paneId, attachment) in tabSnapshot.tmuxAttachments ?? [:] {
                restoredAttachments[paneId] = attachment
            }
        }
        tmuxResolver.restoreAttachments(restoredAttachments)
        paneStates = makeRestoredPaneStates(
            from: restoredTabsByServer,
            snapshotsByTabId: snapshotsByTabId
        )
    }

    private func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistSnapshot()
        }
    }

    private func persistSnapshot() {
        do {
            let data = try JSONEncoder().encode(makeSnapshot())
            snapshotStore.saveSnapshotData(data)
        } catch {
            logger.error("Failed to persist tabs snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = snapshotStore.loadSnapshotData() else { return }
        do {
            let snapshot = try JSONDecoder().decode(TerminalTabsSnapshot.self, from: data)
            isRestoring = true
            applyRestoredSnapshot(snapshot)
        } catch {
            logger.error("Failed to restore tabs snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }

    #if DEBUG
    func persistAndRestoreSnapshotForTesting() {
        persistTask?.cancel()
        persistTask = nil
        persistSnapshot()
        tmuxResolver.clearAllAttachmentState()
        restoreSnapshot()
    }

    func snapshotDataForTesting() throws -> Data {
        try JSONEncoder().encode(makeSnapshot())
    }

    func resetForTesting() {
        persistTask?.cancel()
        persistTask = nil
        isRestoring = true
        tabsByServer.removeAll()
        selectedTabByServer.removeAll()
        paneStates.removeAll()
        connectionViewSelections.resetForTesting()
        isRestoring = false
        snapshotStore.removeSnapshotData()
    }
    #endif
}

struct TerminalServerSessionSnapshot: Equatable {
    let tabs: [TerminalTab]
    let selectedTabId: UUID?
    let connectionStatesByPane: [UUID: ConnectionState]
}

struct TerminalSessionNavigationState: Equatable {
    let tabCountsByServer: [UUID: Int]
    let connectedServerIds: Set<UUID>

    var serverIdsWithTabs: Set<UUID> {
        Set(tabCountsByServer.keys)
    }
}

struct TerminalPanePresentationState: Equatable {
    let connectionState: ConnectionState
    let disconnectReason: TerminalDisconnectReason?
    let hasEstablishedConnection: Bool
    let tmuxStatus: TmuxStatus
    let transportState: ShellTransportState

    init(_ state: TerminalPaneState) {
        connectionState = state.connectionState
        disconnectReason = state.disconnectReason
        hasEstablishedConnection = state.hasEstablishedConnection
        tmuxStatus = state.tmuxStatus
        transportState = state.transportState
    }

    var activeTransport: ShellTransport { transportState.transport }
    var moshFallbackReason: MoshFallbackReason? { transportState.fallbackReason }
    var moshFallbackDiagnostics: MoshFallbackDiagnostics? { transportState.fallbackDiagnostics }
}

private struct TerminalTabsSnapshot: Codable {
    struct ServerSnapshot: Codable {
        let serverId: UUID
        let tabs: [TabSnapshot]
        let selectedTabId: UUID?
        let selectedView: String?
    }

    struct TabSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let layout: TerminalSplitNode?
        let focusedPaneId: UUID
        let rootPaneId: UUID
        let panePresentationOverrides: [UUID: TerminalPresentationOverrides]?
        let paneDisconnectReasons: [UUID: TerminalDisconnectReason]?
        let eternalTerminalTmuxResumeContexts: [UUID: EternalTerminalTmuxResumeContext]?
        let tmuxAttachments: [UUID: TerminalTmuxAttachmentState]?

        init(
            from tab: TerminalTab,
            paneStates: [UUID: TerminalPaneState],
            tmuxResolver: TmuxAttachResolver
        ) {
            id = tab.id
            serverId = tab.serverId
            title = tab.title
            createdAt = tab.createdAt
            layout = tab.layout
            focusedPaneId = tab.focusedPaneId
            rootPaneId = tab.rootPaneId
            let overrides: [UUID: TerminalPresentationOverrides] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let overrides = paneStates[paneId]?.presentationOverrides,
                          !overrides.isEmpty else { return nil }
                    return (paneId, overrides)
                }
            )
            panePresentationOverrides = overrides.isEmpty ? nil : overrides
            let disconnectReasons: [UUID: TerminalDisconnectReason] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let reason = paneStates[paneId]?.disconnectReason else { return nil }
                    return (paneId, reason)
                }
            )
            paneDisconnectReasons = disconnectReasons.isEmpty ? nil : disconnectReasons
            let resumeContexts: [UUID: EternalTerminalTmuxResumeContext] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let context = paneStates[paneId]?.eternalTerminalTmuxResumeContext else {
                        return nil
                    }
                    return (paneId, context)
                }
            )
            eternalTerminalTmuxResumeContexts = resumeContexts.isEmpty ? nil : resumeContexts
            let attachments: [UUID: TerminalTmuxAttachmentState] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    tmuxResolver.attachment(for: paneId).map { (paneId, $0) }
                }
            )
            tmuxAttachments = attachments.isEmpty ? nil : attachments
        }

        func toTerminalTab() -> TerminalTab {
            TerminalTab(
                id: id,
                serverId: serverId,
                title: title,
                createdAt: createdAt,
                rootPaneId: rootPaneId,
                focusedPaneId: focusedPaneId,
                layout: layout
            )
        }
    }

    let servers: [ServerSnapshot]
}
