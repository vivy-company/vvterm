//
//  ActiveServerSummary+iOS.swift
//  VVTerm
//

import Foundation

#if os(iOS)
nonisolated enum ActiveConnectionPresentationStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case resumable
    case failed(String)

    init(
        connectionState: ConnectionState,
        connectionMode: SSHConnectionMode?,
        hasResumeCheckpoint: Bool
    ) {
        if (connectionMode == .eternalTerminal || connectionMode == .mosh),
           hasResumeCheckpoint {
            switch connectionState {
            case .disconnected, .idle:
                self = .resumable
                return
            case .connecting, .connected, .reconnecting, .failed:
                break
            }
        }
        self = switch connectionState {
        case .disconnected, .idle: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting(let attempt): .reconnecting(attempt: attempt)
        case .failed(let failure):
            .failed(TerminalConnectionFailurePresentation.message(for: failure))
        }
    }

    var label: String {
        switch self {
        case .disconnected:
            String(localized: "Disconnected")
        case .connecting:
            String(localized: "Connecting...")
        case .connected:
            String(localized: "Connected")
        case .reconnecting(let attempt):
            String(
                format: String(localized: "Reconnecting (%lld)..."),
                Int64(attempt)
            )
        case .resumable:
            String(localized: "Ready to resume")
        case .failed(let message):
            String(format: String(localized: "Failed: %@"), message)
        }
    }
}

struct ActiveServerSummary: Identifiable {
    let id: UUID
    let terminalTab: TerminalTab?
    let title: String
    let status: ActiveConnectionPresentationStatus
    let tmuxStatus: TmuxStatus
    let tabCount: Int
    let targetView: ConnectionViewTabID

    static func makeAll(
        tabManager: TerminalTabManager,
        fileTabs: RemoteFileTabManager,
        server: (UUID) -> Server?,
        viewTabConfig: ViewTabConfigurationManager
    ) -> [ActiveServerSummary] {
        let serverIds = tabManager.sessionState.serverIdsWithTabs.union(fileTabs.tabsByServer.keys)

        return serverIds.compactMap { serverId in
            let terminalTabs = tabManager.sessionState.tabs(for: serverId)
            let remoteFileTabs = fileTabs.tabs(for: serverId)
            guard !terminalTabs.isEmpty || !remoteFileTabs.isEmpty else { return nil }

            let tab = representativeTab(
                for: serverId,
                tabs: terminalTabs,
                tabManager: tabManager
            )
            let state = representativePaneState(in: terminalTabs, tabManager: tabManager)
            let configuredServer = server(serverId)

            return ActiveServerSummary(
                id: serverId,
                terminalTab: tab,
                title: configuredServer?.name
                    ?? tab.map { tabManager.titleStore.displayTitle(for: $0) }
                    ?? String(localized: "Server"),
                status: state.map {
                    let hasResumeCheckpoint = switch configuredServer?.connectionMode {
                    case .eternalTerminal:
                        tabManager.transportCoordinator.hasEternalTerminalCheckpoint(for: $0.paneId)
                    case .mosh:
                        tabManager.transportCoordinator.hasMoshCheckpoint(for: $0.paneId)
                    case .standard, .tailscale, .cloudflare, .none:
                        false
                    }
                    return ActiveConnectionPresentationStatus(
                        connectionState: $0.connectionState,
                        connectionMode: configuredServer?.connectionMode,
                        hasResumeCheckpoint: hasResumeCheckpoint
                    )
                } ?? .disconnected,
                tmuxStatus: state?.tmuxStatus ?? .off,
                tabCount: terminalTabs.count + remoteFileTabs.count,
                targetView: targetView(
                    serverId: serverId,
                    hasTerminalTabs: !terminalTabs.isEmpty,
                    hasFileTabs: !remoteFileTabs.isEmpty,
                    selectedView: tabManager.connectionViewSelections.selection(for: serverId),
                    viewTabConfig: viewTabConfig
                )
            )
        }
        .sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func representativeTab(
        for serverId: UUID,
        tabs: [TerminalTab],
        tabManager: TerminalTabManager
    ) -> TerminalTab? {
        guard !tabs.isEmpty else { return nil }
        if let selectedId = tabManager.sessionState.selectedTabId(for: serverId),
           let match = tabs.first(where: { $0.id == selectedId }) {
            return match
        }
        return tabs.first
    }

    private static func representativePaneState(
        in tabs: [TerminalTab],
        tabManager: TerminalTabManager
    ) -> TerminalPaneState? {
        tabs
            .flatMap { orderedPaneIds(for: $0) }
            .compactMap { tabManager.sessionState.paneState(for: $0) }
            .min { lhs, rhs in
                stateSortRank(lhs.connectionState) < stateSortRank(rhs.connectionState)
            }
    }

    private static func stateSortRank(_ state: ConnectionState) -> Int {
        switch state {
        case .connected:
            return 0
        case .connecting, .reconnecting:
            return 1
        case .failed:
            return 2
        case .disconnected:
            return 3
        case .idle:
            return 4
        }
    }

    private static func orderedPaneIds(for tab: TerminalTab) -> [UUID] {
        var paneIds = [tab.focusedPaneId, tab.rootPaneId]
        paneIds.append(contentsOf: tab.allPaneIds)
        return paneIds.reduce(into: []) { uniquePaneIds, paneId in
            if !uniquePaneIds.contains(paneId) {
                uniquePaneIds.append(paneId)
            }
        }
    }

    private static func targetView(
        serverId: UUID,
        hasTerminalTabs: Bool,
        hasFileTabs: Bool,
        selectedView: ConnectionViewTabID?,
        viewTabConfig: ViewTabConfigurationManager
    ) -> ConnectionViewTabID {
        let selected = viewTabConfig.effectiveView(for: selectedView)
        switch selected {
        case .stats:
            return .stats
        case .files where hasFileTabs:
            return .files
        case .terminal where hasTerminalTabs:
            return .terminal
        case .files, .terminal:
            return hasTerminalTabs ? .terminal : .files
        }
    }
}
#endif
