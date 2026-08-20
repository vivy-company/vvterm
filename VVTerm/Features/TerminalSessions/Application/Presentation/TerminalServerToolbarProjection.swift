import Combine
import Foundation

@MainActor
final class TerminalPaneTitleStore: ObservableObject {
    @Published private(set) var runtimeTitles: [UUID: String] = [:]
    @Published private(set) var overrides: [UUID: String] = [:]

    @discardableResult
    func setRuntimeTitle(_ title: String, for paneId: UUID) -> Bool {
        guard runtimeTitles[paneId] != title else { return false }
        runtimeTitles[paneId] = title
        return true
    }

    func setOverride(_ title: String?, for paneId: UUID) {
        if let title, !title.isEmpty {
            guard overrides[paneId] != title else { return }
            overrides[paneId] = title
        } else if overrides[paneId] != nil {
            overrides.removeValue(forKey: paneId)
        }
    }

    func removePane(_ paneId: UUID) {
        if runtimeTitles[paneId] != nil {
            runtimeTitles.removeValue(forKey: paneId)
        }
        if overrides[paneId] != nil {
            overrides.removeValue(forKey: paneId)
        }
    }

    func removeAllRuntimeTitles() {
        guard !runtimeTitles.isEmpty else { return }
        runtimeTitles.removeAll()
    }

    func reset() {
        if !runtimeTitles.isEmpty {
            runtimeTitles.removeAll()
        }
        if !overrides.isEmpty {
            overrides.removeAll()
        }
    }

    func displayTitle(forPane paneId: UUID, fallback: String? = nil) -> String? {
        overrides[paneId] ?? runtimeTitles[paneId] ?? fallback
    }

    func displayTitle(for tab: TerminalTab) -> String {
        overrides[tab.focusedPaneId]
            ?? runtimeTitles[tab.focusedPaneId]
            ?? overrides[tab.rootPaneId]
            ?? runtimeTitles[tab.rootPaneId]
            ?? tab.title
    }
}

@MainActor
final class TerminalSessionNavigationProjection: ObservableObject {
    @Published private(set) var state: TerminalSessionNavigationState
    private var cancellable: AnyCancellable?

    init(sessionState: TerminalSessionStateStore) {
        state = sessionState.navigationState
        cancellable = sessionState.navigationChanges
            .sink { [weak self] state in
                guard self?.state != state else { return }
                self?.state = state
            }
    }
}

@MainActor
final class TerminalPanePresentationProjection: ObservableObject {
    @Published private(set) var state: TerminalPanePresentationState?
    private var cancellable: AnyCancellable?

    init(paneId: UUID, sessionState: TerminalSessionStateStore) {
        state = sessionState.presentationState(for: paneId)
        cancellable = sessionState.presentationChanges(for: paneId)
            .sink { [weak self] state in
                guard self?.state != state else { return }
                self?.state = state
            }
    }
}

struct TerminalServerContentState: Equatable {
    let tabs: [TerminalTab]
    let selectedTabId: UUID?
    let selectedView: ConnectionViewTabID?
    let splitZoomedTabIds: Set<UUID>
}

struct TerminalServerToolbarTabItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let connectionState: ConnectionState?
    let paneCount: Int
}

struct TerminalServerToolbarTabStripState: Equatable {
    let items: [TerminalServerToolbarTabItem]
    let selectedTabId: UUID?
}

#if os(iOS)
struct TerminalServerFloatingControlState: Equatable {
    let focusedPaneId: UUID?
    let findNavigatorIsVisible: Bool
    let voicePresentation: TerminalVoicePresentationState
}
#endif

@MainActor
final class TerminalServerContentProjection: ObservableObject {
    @Published private(set) var state: TerminalServerContentState

    init(state: TerminalServerContentState) {
        self.state = state
    }

    fileprivate func update(_ state: TerminalServerContentState) {
        guard self.state != state else { return }
        self.state = state
    }
}

@MainActor
final class TerminalServerToolbarTabStripProjection: ObservableObject {
    @Published private(set) var state: TerminalServerToolbarTabStripState

    init(state: TerminalServerToolbarTabStripState) {
        self.state = state
    }

    fileprivate func update(_ state: TerminalServerToolbarTabStripState) {
        guard self.state != state else { return }
        self.state = state
    }
}

#if os(iOS)
@MainActor
final class TerminalServerFloatingControlProjection: ObservableObject {
    @Published private(set) var state: TerminalServerFloatingControlState

    init(state: TerminalServerFloatingControlState) {
        self.state = state
    }

    fileprivate func update(_ state: TerminalServerFloatingControlState) {
        guard self.state != state else { return }
        self.state = state
    }
}
#endif

/// One per-server projection with separate observable surfaces.
/// Title and connection-status changes redraw only the tab strip. They do not
/// invalidate route chrome or an open menu.
@MainActor
final class TerminalServerToolbarProjection: ObservableObject {
    let content: TerminalServerContentProjection
    let tabStrip: TerminalServerToolbarTabStripProjection
    #if os(iOS)
    let floatingControls: TerminalServerFloatingControlProjection
    #endif

    private var sessionSnapshot: TerminalServerSessionSnapshot
    private var selectedView: ConnectionViewTabID?
    private var runtimeTitles: [UUID: String]
    private var titleOverrides: [UUID: String]
    private var splitZoomedTabIds: Set<UUID>
    #if os(iOS)
    private var findVisibility: [UUID: Bool]
    private var voicePresentation: [UUID: TerminalVoicePresentationState]
    #endif
    private var cancellables: Set<AnyCancellable> = []

    init(serverId: UUID, tabManager: TerminalTabManager) {
        sessionSnapshot = tabManager.sessionState.snapshot(for: serverId)
        selectedView = tabManager.connectionViewSelections.selection(for: serverId)
        runtimeTitles = tabManager.titleStore.runtimeTitles
        titleOverrides = tabManager.titleStore.overrides
        splitZoomedTabIds = tabManager.presentationState.splitZoomedTabIds
        #if os(iOS)
        findVisibility = tabManager.presentationState.terminalFindNavigatorVisibleByPane
        voicePresentation = tabManager.presentationState.terminalVoicePresentationByPane
        #endif

        let initialStates = Self.makeStates(
            sessionSnapshot: sessionSnapshot,
            selectedView: selectedView,
            runtimeTitles: runtimeTitles,
            titleOverrides: titleOverrides,
            splitZoomedTabIds: splitZoomedTabIds
        )
        content = TerminalServerContentProjection(state: initialStates.content)
        tabStrip = TerminalServerToolbarTabStripProjection(state: initialStates.tabStrip)
        #if os(iOS)
        floatingControls = TerminalServerFloatingControlProjection(
            state: Self.makeFloatingControlState(
                sessionSnapshot: sessionSnapshot,
                findVisibility: findVisibility,
                voicePresentation: voicePresentation
            )
        )
        #endif

        tabManager.sessionState.changes(for: serverId)
            .sink { [weak self] snapshot in
                self?.sessionSnapshot = snapshot
                self?.reconcile()
            }
            .store(in: &cancellables)

        tabManager.connectionViewSelections.$selectionsByServer
            .map { $0[serverId] }
            .removeDuplicates()
            .sink { [weak self] selection in
                self?.selectedView = selection
                self?.reconcile()
            }
            .store(in: &cancellables)

        tabManager.titleStore.$runtimeTitles
            .sink { [weak self] titles in
                self?.runtimeTitles = titles
                self?.reconcileTabStrip()
            }
            .store(in: &cancellables)

        tabManager.titleStore.$overrides
            .sink { [weak self] titles in
                self?.titleOverrides = titles
                self?.reconcileTabStrip()
            }
            .store(in: &cancellables)

        tabManager.presentationState.$splitZoomedTabIds
            .sink { [weak self] tabIds in
                self?.splitZoomedTabIds = tabIds
                self?.reconcile()
            }
            .store(in: &cancellables)

        #if os(iOS)
        tabManager.presentationState.$terminalFindNavigatorVisibleByPane
            .sink { [weak self] visibility in
                self?.findVisibility = visibility
                self?.reconcileFloatingControls()
            }
            .store(in: &cancellables)

        tabManager.presentationState.$terminalVoicePresentationByPane
            .sink { [weak self] presentation in
                self?.voicePresentation = presentation
                self?.reconcileFloatingControls()
            }
            .store(in: &cancellables)
        #endif
    }

    private func reconcile() {
        let states = Self.makeStates(
            sessionSnapshot: sessionSnapshot,
            selectedView: selectedView,
            runtimeTitles: runtimeTitles,
            titleOverrides: titleOverrides,
            splitZoomedTabIds: splitZoomedTabIds
        )
        #if os(iOS)
        let floatingState = Self.makeFloatingControlState(
            sessionSnapshot: sessionSnapshot,
            findVisibility: findVisibility,
            voicePresentation: voicePresentation
        )
        let routeStateChanged = content.state != states.content
            || floatingControls.state != floatingState
        #else
        let routeStateChanged = content.state != states.content
        #endif
        if routeStateChanged {
            objectWillChange.send()
        }
        content.update(states.content)
        tabStrip.update(states.tabStrip)
        #if os(iOS)
        floatingControls.update(floatingState)
        #endif
    }

    private func reconcileTabStrip() {
        tabStrip.update(
            Self.makeTabStripState(
                sessionSnapshot: sessionSnapshot,
                runtimeTitles: runtimeTitles,
                titleOverrides: titleOverrides
            )
        )
    }

    #if os(iOS)
    private func reconcileFloatingControls() {
        let state = Self.makeFloatingControlState(
            sessionSnapshot: sessionSnapshot,
            findVisibility: findVisibility,
            voicePresentation: voicePresentation
        )
        guard floatingControls.state != state else { return }
        objectWillChange.send()
        floatingControls.update(state)
    }
    #endif

    private static func makeStates(
        sessionSnapshot: TerminalServerSessionSnapshot,
        selectedView: ConnectionViewTabID?,
        runtimeTitles: [UUID: String],
        titleOverrides: [UUID: String],
        splitZoomedTabIds: Set<UUID>
    ) -> (
        content: TerminalServerContentState,
        tabStrip: TerminalServerToolbarTabStripState
    ) {
        let tabs = sessionSnapshot.tabs
        let selectedTab = resolvedSelectedTab(in: sessionSnapshot)
        let content = TerminalServerContentState(
            tabs: tabs,
            selectedTabId: selectedTab?.id,
            selectedView: selectedView,
            splitZoomedTabIds: splitZoomedTabIds.intersection(tabs.map(\.id))
        )
        return (
            content,
            makeTabStripState(
                sessionSnapshot: sessionSnapshot,
                runtimeTitles: runtimeTitles,
                titleOverrides: titleOverrides
            )
        )
    }

    private static func makeTabStripState(
        sessionSnapshot: TerminalServerSessionSnapshot,
        runtimeTitles: [UUID: String],
        titleOverrides: [UUID: String]
    ) -> TerminalServerToolbarTabStripState {
        TerminalServerToolbarTabStripState(
            items: sessionSnapshot.tabs.map { tab in
                TerminalServerToolbarTabItem(
                    id: tab.id,
                    title: displayTitle(
                        for: tab,
                        runtimeTitles: runtimeTitles,
                        titleOverrides: titleOverrides
                    ),
                    connectionState: sessionSnapshot.connectionStatesByPane[tab.focusedPaneId],
                    paneCount: tab.paneCount
                )
            },
            selectedTabId: resolvedSelectedTab(in: sessionSnapshot)?.id
        )
    }

    private static func resolvedSelectedTab(
        in sessionSnapshot: TerminalServerSessionSnapshot
    ) -> TerminalTab? {
        if let selectedTabId = sessionSnapshot.selectedTabId,
           let selected = sessionSnapshot.tabs.first(where: { $0.id == selectedTabId }) {
            return selected
        }
        return sessionSnapshot.tabs.first
    }

    private static func displayTitle(
        for tab: TerminalTab,
        runtimeTitles: [UUID: String],
        titleOverrides: [UUID: String]
    ) -> String {
        titleOverrides[tab.focusedPaneId]
            ?? runtimeTitles[tab.focusedPaneId]
            ?? titleOverrides[tab.rootPaneId]
            ?? runtimeTitles[tab.rootPaneId]
            ?? tab.title
    }

    #if os(iOS)
    private static func makeFloatingControlState(
        sessionSnapshot: TerminalServerSessionSnapshot,
        findVisibility: [UUID: Bool],
        voicePresentation: [UUID: TerminalVoicePresentationState]
    ) -> TerminalServerFloatingControlState {
        let paneId = resolvedSelectedTab(in: sessionSnapshot)?.focusedPaneId
        return TerminalServerFloatingControlState(
            focusedPaneId: paneId,
            findNavigatorIsVisible: paneId.flatMap { findVisibility[$0] } ?? false,
            voicePresentation: paneId.flatMap { voicePresentation[$0] } ?? .idle
        )
    }
    #endif
}
