//
//  TerminalTabManager.swift
//  VVTerm
//
//  Manages terminal tabs and their panes.
//  - Tabs are shown in the toolbar
//  - Each tab can have multiple panes via splits
//  - Panes are NOT tabs - they're split views within a tab
//

import Foundation
import Combine
import os.log

@MainActor
final class TerminalTabManager {
    // MARK: - Session State

    let sessionState: TerminalSessionStateStore
    let connectionViewSelections: ConnectionViewSelectionStore
    let presentationState = TerminalPresentationStateStore()

    // MARK: - Terminal Registry

    let terminalSurfaceStore: any TerminalSurfaceStoring
    let transportCoordinator: TerminalTransportCoordinator
    lazy var reconnectCoordinator = makeReconnectCoordinator()
    /// The current tab-open authorization attempt for each server.
    private var tabOpenAttemptsByServer: [UUID: UUID] = [:]

    let titleStore = TerminalPaneTitleStore()
    let richPasteRuntimeStore = TerminalRichPasteRuntimeStore()
    #if os(iOS)
    let keyboardCoordinator = TerminalKeyboardCoordinator()
    #endif

    let tmuxCoordinator: TerminalTmuxSessionCoordinator

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    private let dependencies: TerminalTabManagerDependencies
    private var stateCancellables: Set<AnyCancellable> = []

    init(
        snapshotStore: any TerminalTabSnapshotStoring,
        dependencies: TerminalTabManagerDependencies,
        tmuxConfiguration: TerminalTmuxConfiguration,
        remoteTmux: any TerminalRemoteTmuxServicing,
        terminalSurfaceStore: any TerminalSurfaceStoring,
        eternalTerminalResumeStore: any EternalTerminalResumeStoring,
        moshRecovery: any TerminalMoshRecoveryServicing
    ) {
        self.dependencies = dependencies
        let connectionViewSelections = ConnectionViewSelectionStore()
        let tmuxResolver = TmuxAttachResolver(
            configuration: tmuxConfiguration,
            remoteTmux: remoteTmux
        )
        let transportLifetime = TerminalTransportLifetime()
        let runtimeEvents = PassthroughSubject<TerminalTransportSessionEvent, Never>()
        self.connectionViewSelections = connectionViewSelections
        let sessionState = TerminalSessionStateStore(
            snapshotStore: snapshotStore,
            connectionViewSelections: connectionViewSelections,
            tmuxResolver: tmuxResolver
        )
        self.sessionState = sessionState
        let tmuxCoordinator = TerminalTmuxSessionCoordinator(
            configuration: tmuxConfiguration,
            remoteTmux: remoteTmux,
            resolver: tmuxResolver,
            sessionState: sessionState,
            transportLifetime: transportLifetime
        )
        self.tmuxCoordinator = tmuxCoordinator
        self.terminalSurfaceStore = terminalSurfaceStore
        self.transportCoordinator = TerminalTransportCoordinator(
            lifetime: transportLifetime,
            sshClientFactory: dependencies.sshClientFactory,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshRecovery: moshRecovery,
            remoteMosh: dependencies.remoteMosh,
            eternalTerminalRuntimeDependencies: dependencies.eternalTerminalRuntime,
            sessionAccess: TerminalTransportSessionAccess(
                paneState: { [weak sessionState] paneId in
                    sessionState?.paneState(for: paneId)
                },
                allPaneStates: { [weak sessionState] in
                    sessionState?.allPaneStates ?? []
                },
                selectedTab: { [weak sessionState] serverId in
                    sessionState?.selectedTab(for: serverId)
                },
                tabs: { [weak sessionState] serverId in
                    sessionState?.tabs(for: serverId) ?? []
                },
                containsPane: { [weak sessionState] paneId in
                    sessionState?.containsPane(paneId) == true
                },
                workingDirectory: { [weak sessionState] paneId in
                    sessionState?.paneState(for: paneId)?.workingDirectory
                },
                shouldApplyWorkingDirectory: { [weak tmuxCoordinator] paneId in
                    tmuxCoordinator?.shouldApplyWorkingDirectory(for: paneId) == true
                },
                send: { event in
                    runtimeEvents.send(event)
                }
            ),
            tmuxCoordinator: tmuxCoordinator
        )
        runtimeEvents
            .sink { [weak self] event in
                self?.handleTransportSessionEvent(event)
            }
            .store(in: &stateCancellables)
        #if os(iOS)
        keyboardCoordinator.terminalProvider = { [weak self] paneId in
            self?.terminalSurfaceStore.surface(for: paneId)?.keyboardInputSession
        }
        #endif
        sessionState.selectedTabChanges
            .dropFirst()
            .sink { [weak self] selectedTabs in
                self?.tmuxCoordinator.updateSelectionStatuses(selectedTabs: selectedTabs)
            }
            .store(in: &stateCancellables)
        sessionState.paneConnectionStateChanges
            .dropFirst()
            .sink { [weak self] connectionStates in
                self?.dependencies.effects.refreshLiveActivity(connectionStates)
            }
            .store(in: &stateCancellables)
        _ = reconnectCoordinator
        dependencies.effects.refreshLiveActivity(
            sessionState.connectionStates
        )
    }

    private func handleTransportSessionEvent(_ event: TerminalTransportSessionEvent) {
        switch event {
        case .activeTransport(let paneId, let state):
            setPaneTransport(state, for: paneId)
        case .eternalTerminalResumeContext(let paneId, let context):
            setEternalTerminalTmuxResumeContext(context, for: paneId)
        case .connectionState(let paneId, let state):
            updatePaneState(paneId, connectionState: state)
        case .title(let paneId, let title):
            updatePaneTitle(paneId, rawTitle: title)
        case .shellEnd(let paneId, let reason, let ownership):
            handleShellEnd(for: paneId, reason: reason, ownership: ownership)
        }
    }

    private func makeReconnectCoordinator() -> TerminalReconnectCoordinator {
        let access: TerminalReconnectAccess
        #if os(macOS)
        access = TerminalReconnectAccess(
            paneFacts: { [weak self] paneId in
                self?.reconnectPaneFacts(for: paneId)
            },
            paneIDs: { [weak self] in
                self.map { Array($0.sessionState.paneIds) } ?? []
            },
            paneIDsForServer: { [weak self] serverId in
                self?.sessionState.paneStates(forServer: serverId).map(\.paneId) ?? []
            },
            networkPathBecameReady: { [weak self] paneId in
                self?.transportCoordinator.notifyEternalTerminalNetworkPathChanged(for: paneId)
            },
            prepareTransport: { [weak self] paneId in
                await self?.transportCoordinator.prepareTransportForReconnect(paneId)
            },
            startConnection: { [weak self] paneId in
                self?.startReconnectConnection(paneId) == true
            },
            failConnection: { [weak self] paneId in
                self?.failReconnect(paneId)
            },
            offlineMacRecoveryPaneIDs: { [weak self] in
                self?.offlineMacRecoveryPaneIDs ?? []
            },
            macRecoveryCandidates: { [weak self] in
                self?.macRecoveryCandidates ?? []
            },
            beginEternalTerminalProbe: { [weak self] paneId in
                await self?.transportCoordinator.beginEternalTerminalNetworkRecoveryProbe(for: paneId)
            },
            hasVerifiedLiveTransport: { [weak self] paneId, probeID in
                await self?.transportCoordinator.hasVerifiedLiveTransport(
                    for: paneId,
                    eternalTerminalProbeID: probeID
                ) == true
            },
            markMoshConnected: { [weak self] paneId in
                self?.markMoshConnectedAfterRecoveryIfNeeded(for: paneId)
            }
        )
        #else
        access = TerminalReconnectAccess(
            paneFacts: { [weak self] paneId in
                self?.reconnectPaneFacts(for: paneId)
            },
            paneIDs: { [weak self] in
                self.map { Array($0.sessionState.paneIds) } ?? []
            },
            paneIDsForServer: { [weak self] serverId in
                self?.sessionState.paneStates(forServer: serverId).map(\.paneId) ?? []
            },
            networkPathBecameReady: { [weak self] paneId in
                self?.transportCoordinator.notifyEternalTerminalNetworkPathChanged(for: paneId)
            },
            prepareTransport: { [weak self] paneId in
                await self?.transportCoordinator.prepareTransportForReconnect(paneId)
            },
            startConnection: { [weak self] paneId in
                self?.startReconnectConnection(paneId) == true
            },
            failConnection: { [weak self] paneId in
                self?.failReconnect(paneId)
            }
        )
        #endif
        return TerminalReconnectCoordinator(
            access: access,
            initialNetworkReadiness: dependencies.networkReadiness.initial,
            networkUpdates: dependencies.networkReadiness.updates,
            applicationIsActive: dependencies.applicationIsActive,
            initialAppIsLocked: dependencies.appLock.initialIsLocked,
            appLockUpdates: dependencies.appLock.updates,
            onEvent: { [weak self] event in
                self?.logReconnectEvent(event)
            },
            onChange: {}
        )
    }

    #if DEBUG
    convenience init(
        snapshotStore: any TerminalTabSnapshotStoring,
        networkReadinessPublisher: AnyPublisher<TerminalNetworkReadiness, Never>?,
        liveActivityRefresh: @escaping ([ConnectionState]) -> Void,
        tmuxConfiguration: TerminalTmuxConfiguration = .testing,
        remoteTmux: any TerminalRemoteTmuxServicing = UnavailableTerminalRemoteTmuxService(),
        terminalSurfaceStore: any TerminalSurfaceStoring,
        eternalTerminalResumeStore: any EternalTerminalResumeStoring,
        moshRecovery: any TerminalMoshRecoveryServicing
    ) {
        self.init(
            snapshotStore: snapshotStore,
            dependencies: .testing(
                networkReadinessPublisher: networkReadinessPublisher,
                liveActivityRefresh: liveActivityRefresh
            ),
            tmuxConfiguration: tmuxConfiguration,
            remoteTmux: remoteTmux,
            terminalSurfaceStore: terminalSurfaceStore,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshRecovery: moshRecovery
        )
    }
    #endif

    private func setPaneWorkingDirectory(_ workingDirectory: String, for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.workingDirectory = workingDirectory }
    }

    private func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized: String
        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            normalized = path.removingPercentEncoding ?? path
        } else {
            normalized = trimmed
        }

        guard normalized.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return normalized
    }

    private func setPanePresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides, for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.presentationOverrides = presentationOverrides }
    }

    private func setPaneTitle(_ title: String, for paneId: UUID) {
        guard titleStore.setRuntimeTitle(title, for: paneId) else { return }
        logger.info("Runtime pane title changed: \(title, privacy: .public)")
    }

    private func setPaneTransport(_ state: ShellTransportState, for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.transportState = state }
    }

    // MARK: - Tab Management

    func workingDirectoryCandidate(for serverId: UUID) -> String? {
        if let selectedTab = sessionState.selectedTab(for: serverId),
           let directory = sessionState.paneState(for: selectedTab.focusedPaneId)?.workingDirectory {
            return directory
        }
        return sessionState.firstPaneState(for: serverId)?.workingDirectory
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        if tabOpenAttemptsByServer[server.id] != nil {
            throw TerminalTabOpeningError.alreadyOpening
        }
        let attemptID = UUID()
        tabOpenAttemptsByServer[server.id] = attemptID
        defer {
            if tabOpenAttemptsByServer[server.id] == attemptID {
                tabOpenAttemptsByServer[server.id] = nil
            }
        }

        let isAuthorized = await dependencies.effects.authorizeServer(server)
        try Task.checkCancellation()
        guard tabOpenAttemptsByServer[server.id] == attemptID else {
            throw CancellationError()
        }
        guard isAuthorized else {
            throw VVTermError.authenticationFailed
        }

        let sourcePaneId = sessionState.selectedTab(for: server.id)?.focusedPaneId
        let sourceWorkingDirectory = sourcePaneId
            .flatMap { sessionState.paneState(for: $0)?.workingDirectory }
        let tab = sessionState.createTab(
            serverId: server.id,
            title: server.name,
            sourcePaneId: sourcePaneId,
            sourceWorkingDirectory: sourceWorkingDirectory,
            tmuxStatus: tmuxCoordinator.isEnabled(for: server.id) ? .unknown : .off
        )

        logger.info("Opened new tab for \(server.name), pane: \(tab.rootPaneId)")
        return tab
    }

    /// Close a tab
    func closeTab(_ tab: TerminalTab) {
        closeTab(tab, intent: .explicitClose)
    }

    private func closeTab(
        _ tab: TerminalTab,
        intent: TerminalTeardownIntent
    ) {
        guard let currentTab = sessionState.tab(id: tab.id, for: tab.serverId) else {
            logger.warning("closeTab: tab not found \(tab.id.uuidString, privacy: .public)")
            return
        }

        presentationState.removeTab(currentTab.id)

        // Clean up all panes in this tab
        for paneId in currentTab.allPaneIds {
            cleanupPane(paneId, intent: intent)
        }

        sessionState.removeTab(currentTab)

        dependencies.effects.noteTerminalSessionEnded(hasConnectedPanes)

        logger.info("Closed tab \(currentTab.id)")
    }

    /// Close all tabs for a server
    func closeAllTabs(for serverId: UUID) {
        tabOpenAttemptsByServer[serverId] = nil
        closeAllTabs(for: serverId, intent: .explicitClose)
    }

    private func closeAllTabs(
        for serverId: UUID,
        intent: TerminalTeardownIntent
    ) {
        let serverTabs = sessionState.tabs(for: serverId)
        for tab in serverTabs {
            closeTab(tab, intent: intent)
        }
    }

    /// Disconnect all terminal tabs for a specific server.
    func disconnectServer(_ serverId: UUID) {
        tabOpenAttemptsByServer[serverId] = nil
        closeAllTabs(for: serverId, intent: .explicitServerDisconnect)
        sessionState.removeServer(serverId)
        sessionState.selectView(nil, for: serverId)
        sessionState.persistNow()
        logger.info("Disconnected all terminal tabs for server \(serverId.uuidString, privacy: .public)")
    }

    /// Disconnect every active terminal tab.
    func disconnectAll() {
        tabOpenAttemptsByServer.removeAll()
        for serverId in sessionState.serverIdsWithTabs {
            disconnectServer(serverId)
        }
        sessionState.persistNow()
        logger.info("Disconnected all terminal tabs")
    }

    /// Flushes reconnectable state and releases local runtime resources without
    /// deleting tabs or terminating remote resumable sessions.
    @discardableResult
    func beginApplicationTermination() -> Task<Void, Never> {
        let paneIds = sessionState.prepareForApplicationTermination()
            .union(transportCoordinator.ownedPaneIds)
        reconnectCoordinator.prepareForApplicationTermination()
        tabOpenAttemptsByServer.removeAll()
        for paneId in paneIds {
            detachTerminalRegistration(for: paneId)
        }
        richPasteRuntimeStore.removeAll()
        titleStore.removeAllRuntimeTitles()

        logger.info("Preserved terminal tabs while releasing application runtime state")
        return transportCoordinator.beginApplicationTermination(paneIds: paneIds)
    }

    private func reconnectPaneFacts(for paneId: UUID) -> TerminalReconnectPaneFacts? {
        sessionState.paneState(for: paneId).map {
            TerminalReconnectPaneFacts(
                connectionState: $0.connectionState,
                hasEstablishedConnection: $0.hasEstablishedConnection
            )
        }
    }

    #if os(macOS)
    private var offlineMacRecoveryPaneIDs: [UUID] {
        sessionState.allPaneStates.compactMap { paneState in
            MacTerminalRecoveryPolicy.shouldPrepareWhileOffline(
                connectionState: paneState.connectionState,
                hasEstablishedConnection: paneState.hasEstablishedConnection
            ) ? paneState.paneId : nil
        }
    }

    private var macRecoveryCandidates: [MacTerminalRecoveryCandidate] {
        sessionState.allPaneStates.compactMap { paneState in
            let strategy = MacTerminalRecoveryPolicy.readyStrategy(
                connectionState: paneState.connectionState,
                hasEstablishedConnection: paneState.hasEstablishedConnection,
                activeTransport: paneState.activeTransport,
                hasEternalTerminalRuntime: transportCoordinator.hasEternalTerminalRuntime(for: paneState.paneId)
            )
            return strategy == .ignore
                ? nil
                : MacTerminalRecoveryCandidate(paneId: paneState.paneId, strategy: strategy)
        }
    }

    private func markMoshConnectedAfterRecoveryIfNeeded(for paneId: UUID) {
        guard sessionState.paneState(for: paneId)?.activeTransport == .mosh,
              sessionState.paneState(for: paneId)?.connectionState.isConnected != true else {
            return
        }
        updatePaneState(paneId, connectionState: .connected)
    }
    #endif

    private func startReconnectConnection(_ paneId: UUID) -> Bool {
        guard let paneState = sessionState.paneState(for: paneId) else { return false }
        updatePaneState(
            paneId,
            connectionState: TerminalConnectionAttemptPolicy.state(
                attempt: 1,
                hasEstablishedConnection: paneState.hasEstablishedConnection
            )
        )
        return true
    }

    private func failReconnect(_ paneId: UUID) {
        guard sessionState.containsPane(paneId) else { return }
        logger.error("Reconnect deadline exceeded for pane \(paneId.uuidString, privacy: .public)")
        if sessionState.paneState(for: paneId)?.disconnectReason != nil {
            sessionState.updatePane(paneId, persist: true) {
                $0.disconnectReason = nil
            }
        }
        updatePaneState(
            paneId,
            connectionState: .failed(.reconnectTimedOut)
        )
    }

    private func logReconnectEvent(_ event: TerminalReconnectCoordinator.Event) {
        logger.info(
            "Reconnect stage=\(event.stage.rawValue, privacy: .public) monotonic=\(event.systemUptime, privacy: .public) pane=\(event.attempt.paneId.uuidString, privacy: .public) attempt=\(event.attempt.id.uuidString, privacy: .public) generation=\(event.attempt.generation.uuidString, privacy: .public)"
        )
    }

    func clearMoshFallbackDiagnostics(for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.transportState.clearFallbackDiagnostics() }
    }

    // MARK: - Split Management

    /// Split a pane horizontally (left | right)
    func splitHorizontal(
        tab: TerminalTab,
        paneId: UUID,
        hasProAccess: Bool
    ) -> UUID? {
        splitRight(tab: tab, paneId: paneId, hasProAccess: hasProAccess)
    }

    func splitRight(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .right,
            hasProAccess: hasProAccess
        )
    }

    func splitLeft(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .left,
            hasProAccess: hasProAccess
        )
    }

    func splitDown(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .down,
            hasProAccess: hasProAccess
        )
    }

    func splitUp(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .up,
            hasProAccess: hasProAccess
        )
    }

    private func splitPane(
        tab: TerminalTab,
        paneId: UUID,
        placement: TerminalSplitPlacement,
        hasProAccess: Bool
    ) -> UUID? {
        guard hasProAccess else { return nil }
        let newPaneId = createSplitPane(tab: tab, paneId: paneId, placement: placement)
        if newPaneId != nil {
            dependencies.effects.recordSplitPaneCreated()
        }
        return newPaneId
    }

    private func createSplitPane(tab: TerminalTab, paneId: UUID, placement: TerminalSplitPlacement) -> UUID? {
        guard let currentTab = sessionState.tab(id: tab.id, for: tab.serverId),
              let newPaneId = sessionState.createSplitPane(
                  in: currentTab,
                  paneId: paneId,
                  placement: placement,
                  tmuxStatus: tmuxCoordinator.isEnabled(for: currentTab.serverId) ? .unknown : .off
              ) else {
            logger.warning("createSplitPane: tab or pane not found")
            return nil
        }
        if let updatedTab = sessionState.tab(id: currentTab.id, for: currentTab.serverId) {
            tmuxCoordinator.updateFocus(for: updatedTab)
        }
        logger.info("Split pane \(paneId) \(placement.direction.rawValue), new pane: \(newPaneId)")
        return newPaneId
    }

    /// Close a pane within a tab
    func closePane(tab: TerminalTab, paneId: UUID) {
        closePane(tab: tab, paneId: paneId, intent: .explicitClose)
    }

    private func closePane(
        tab: TerminalTab,
        paneId: UUID,
        intent: TerminalTeardownIntent
    ) {
        guard let removal = sessionState.removePane(in: tab, paneId: paneId) else {
            logger.warning("closePane: tab not found")
            return
        }
        switch removal {
        case .closeTab(let currentTab):
            closeTab(currentTab, intent: intent)
        case .removed(let removedPaneId, let paneState, let updatedTab):
            tmuxCoordinator.updateFocus(for: updatedTab)
            cleanupPane(
                removedPaneId,
                removedPaneState: paneState,
                intent: intent
            )
            logger.info("Closed pane \(removedPaneId)")
        }
    }

    func focusPane(in tab: TerminalTab, paneId: UUID) {
        guard let updatedTab = sessionState.focusPane(in: tab, paneId: paneId) else { return }
        tmuxCoordinator.updateFocus(for: updatedTab)
    }

    func updateSplitRatio(
        in tab: TerminalTab,
        node: TerminalSplitNode,
        ratio: Double
    ) {
        guard let updatedTab = sessionState.updateSplitRatio(
            in: tab,
            node: node,
            ratio: ratio
        ) else { return }
        tmuxCoordinator.updateFocus(for: updatedTab)
    }

    func equalizeSplitLayout(in tab: TerminalTab) {
        guard let updatedTab = sessionState.equalizeSplitLayout(in: tab) else { return }
        tmuxCoordinator.updateFocus(for: updatedTab)
    }

    func isSplitZoomed(in tab: TerminalTab) -> Bool {
        guard presentationState.splitZoomedTabIds.contains(tab.id),
              let currentTab = sessionState.tab(id: tab.id, for: tab.serverId) else {
            return false
        }
        return currentTab.hasSplits
    }

    func canPerformSplitCommand(
        _ command: TerminalSplitCommand,
        in tab: TerminalTab
    ) -> Bool {
        guard let currentTab = sessionState.tab(id: tab.id, for: tab.serverId),
              currentTab.allPaneIds.contains(currentTab.focusedPaneId) else {
            return false
        }

        switch command {
        case .splitRight, .splitDown, .closeFocusedPane:
            return true
        case .toggleZoom, .selectPrevious, .selectNext, .equalize:
            return currentTab.hasSplits
        case .selectAbove:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .above
            ) != nil
        case .selectBelow:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .below
            ) != nil
        case .selectLeft:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .left
            ) != nil
        case .selectRight:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .right
            ) != nil
        case .moveDividerUp:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .up
            ) == true
        case .moveDividerDown:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .down
            ) == true
        case .moveDividerLeft:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .left
            ) == true
        case .moveDividerRight:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .right
            ) == true
        }
    }

    @discardableResult
    func performSplitCommand(
        _ command: TerminalSplitCommand,
        in tab: TerminalTab,
        hasProAccess: Bool
    ) -> TerminalSplitCommandOutcome {
        guard canPerformSplitCommand(command, in: tab),
              let currentTab = sessionState.tab(id: tab.id, for: tab.serverId) else {
            return .unavailable
        }

        switch command {
        case .splitRight:
            guard hasProAccess else { return .requiresUpgrade }
            return splitRight(
                tab: currentTab,
                paneId: currentTab.focusedPaneId,
                hasProAccess: hasProAccess
            ) == nil
                ? .unavailable
                : .performed
        case .splitDown:
            guard hasProAccess else { return .requiresUpgrade }
            return splitDown(
                tab: currentTab,
                paneId: currentTab.focusedPaneId,
                hasProAccess: hasProAccess
            ) == nil
                ? .unavailable
                : .performed
        case .closeFocusedPane:
            return .requiresCloseConfirmation
        case .toggleZoom:
            presentationState.toggleSplitZoom(for: currentTab.id)
        case .selectPrevious:
            guard let paneId = currentTab.layout?.pane(before: currentTab.focusedPaneId) else {
                return .unavailable
            }
            guard let updatedTab = sessionState.selectAdjacentPane(in: currentTab, paneId: paneId) else {
                return .unavailable
            }
            tmuxCoordinator.updateFocus(for: updatedTab)
        case .selectNext:
            guard let paneId = currentTab.layout?.pane(after: currentTab.focusedPaneId) else {
                return .unavailable
            }
            guard let updatedTab = sessionState.selectAdjacentPane(in: currentTab, paneId: paneId) else {
                return .unavailable
            }
            tmuxCoordinator.updateFocus(for: updatedTab)
        case .selectAbove:
            return selectNeighbor(in: currentTab, direction: .above)
        case .selectBelow:
            return selectNeighbor(in: currentTab, direction: .below)
        case .selectLeft:
            return selectNeighbor(in: currentTab, direction: .left)
        case .selectRight:
            return selectNeighbor(in: currentTab, direction: .right)
        case .equalize:
            guard let updatedTab = sessionState.equalizeSplitLayout(in: currentTab) else {
                return .unavailable
            }
            tmuxCoordinator.updateFocus(for: updatedTab)
        case .moveDividerUp:
            return moveDivider(in: currentTab, direction: .up)
        case .moveDividerDown:
            return moveDivider(in: currentTab, direction: .down)
        case .moveDividerLeft:
            return moveDivider(in: currentTab, direction: .left)
        case .moveDividerRight:
            return moveDivider(in: currentTab, direction: .right)
        }

        return .performed
    }

    private func selectNeighbor(
        in tab: TerminalTab,
        direction: TerminalSplitFocusDirection
    ) -> TerminalSplitCommandOutcome {
        guard let currentTab = sessionState.tab(id: tab.id, for: tab.serverId),
              let paneId = currentTab.layout?.neighboringPane(
                  from: currentTab.focusedPaneId,
                  direction: direction
              ) else {
            return .unavailable
        }
        guard let updatedTab = sessionState.selectAdjacentPane(in: currentTab, paneId: paneId) else {
            return .unavailable
        }
        tmuxCoordinator.updateFocus(for: updatedTab)
        return .performed
    }

    private func moveDivider(
        in tab: TerminalTab,
        direction: TerminalSplitResizeDirection
    ) -> TerminalSplitCommandOutcome {
        guard let updatedTab = sessionState.moveDivider(in: tab, direction: direction) else {
            return .unavailable
        }
        tmuxCoordinator.updateFocus(for: updatedTab)
        return .performed
    }

    // MARK: - Terminal Registry

    func registerTerminalSurface(_ terminal: any TerminalSurface, for paneId: UUID) {
        #if os(iOS)
        terminal.setLifecycleCallbacks(TerminalSurfaceLifecycleCallbacks(
            windowAttachmentChanged: { [weak self, weak terminal] _ in
                Task { @MainActor [weak self, weak terminal] in
                    guard let self, let terminal,
                          self.terminalSurfaceStore.isRegistered(
                            terminal,
                            for: paneId
                          ) else { return }
                    self.keyboardCoordinator.setWindowAttached(
                        terminal.isAttachedToWindow,
                        for: paneId
                    )
                }
            },
            directTouch: { [weak self, weak terminal] isFocusTap in
                guard let self, let terminal,
                      self.terminalSurfaceStore.isRegistered(
                        terminal,
                        for: paneId
                      ) else { return }
                self.keyboardCoordinator.setActivePane(paneId)
                self.keyboardCoordinator.directTouchOnTerminal(isFocusTap: isFocusTap)
            },
            keyboardAccessoryHideRequested: { [weak self] in
                self?.keyboardCoordinator.userRequestedHide()
            },
            findNavigatorVisibilityChanged: { [weak self, weak terminal] isVisible in
                guard let self, let terminal,
                      self.terminalSurfaceStore.isRegistered(
                        terminal,
                        for: paneId
                      ) else { return }
                self.setTerminalFindNavigatorVisible(isVisible, for: paneId)
                self.keyboardCoordinator.setFindNavigatorActive(isVisible, for: paneId)
            }
        ))
        #endif
        let replacesRegisteredTerminal = terminalSurfaceStore.register(terminal, for: paneId)
        #if os(iOS)
        terminal.acceptsTerminalInput = sessionState.paneState(for: paneId)?.connectionState.isConnected == true
        // A replacement is commonly registered before UIKit attaches it.
        // Publish that fact before reconciling its new identity so the
        // coordinator cannot spend an acquisition or repair off-window.
        keyboardCoordinator.setWindowAttached(terminal.isAttachedToWindow, for: paneId)
        if replacesRegisteredTerminal {
            keyboardCoordinator.terminalProviderIdentityDidChange(for: paneId)
        }
        Task { @MainActor [weak self, weak terminal] in
            guard let self, let terminal,
                  self.terminalSurfaceStore.isRegistered(terminal, for: paneId) else { return }
            self.keyboardCoordinator.setWindowAttached(
                terminal.isAttachedToWindow,
                for: paneId
            )
            self.publishTerminalInputAvailability(for: paneId)
            self.setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: paneId)
            self.keyboardCoordinator.setFindNavigatorActive(
                terminal.isFindNavigatorVisible,
                for: paneId
            )
        }
        #endif
    }

    @discardableResult
    private func detachTerminalRegistration(
        for paneId: UUID
    ) -> (any TerminalSurface)? {
        terminalSurfaceStore.remove(for: paneId) { [self] terminal in
            prepareTerminalSurfaceRemoval(terminal, for: paneId)
        }
    }

    /// Unregister a dismantled platform view only if it is still the pane's
    /// registered terminal. SwiftUI may create its replacement before the old
    /// view's deferred teardown runs during window reconstruction.
    func unregisterTerminalSurface(
        _ terminal: any TerminalSurface,
        for paneId: UUID
    ) {
        terminalSurfaceStore.unregister(
            terminal,
            for: paneId,
            prepareForRemoval: { [self] current in
                prepareTerminalSurfaceRemoval(current, for: paneId)
            },
            cleanup: { $0.cleanup() }
        )
    }

    private func prepareTerminalSurfaceRemoval(
        _ terminal: any TerminalSurface,
        for paneId: UUID
    ) {
        #if os(iOS)
        terminal.setLifecycleCallbacks(nil)
        presentationState.removePane(paneId)
        keyboardCoordinator.setWindowAttached(false, for: paneId)
        keyboardCoordinator.removePane(paneId)
        #endif
    }

    private func drainTerminalSurfaces() {
        terminalSurfaceStore.drain(
            prepareForRemoval: { [self] paneId, terminal in
                prepareTerminalSurfaceRemoval(terminal, for: paneId)
            },
            cleanup: { $0.cleanup() }
        )
    }

    #if os(iOS)
    private func setTerminalFindNavigatorVisible(_ isVisible: Bool, for paneId: UUID) {
        presentationState.setTerminalFindNavigatorVisible(isVisible, for: paneId)
    }
    #endif

    private func setEternalTerminalTmuxResumeContext(
        _ context: EternalTerminalTmuxResumeContext?,
        for paneId: UUID
    ) {
        guard sessionState.paneState(for: paneId)?.eternalTerminalTmuxResumeContext != context else { return }
        sessionState.updatePane(paneId, persist: true) {
            $0.eternalTerminalTmuxResumeContext = context
        }
    }

    /// DEV-228 compatibility for the excluded SSHSFTPAdapter default provider.
    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        transportCoordinator.sharedStatsClient(for: serverId)
    }

    /// Clean up a pane (terminal + SSH)
    private func cleanupPane(
        _ paneId: UUID,
        removedPaneState: TerminalPaneState? = nil,
        intent: TerminalTeardownIntent = .explicitClose
    ) {
        guard intent.removesPersistedDescriptor else {
            assertionFailure("Application termination must preserve the pane descriptor")
            return
        }
        let tmuxSessionToKill = intent.terminatesManagedTmux
            ? (removedPaneState?.tmuxStatus ?? tmuxCoordinator.status(for: paneId))
                .flatMap { tmuxCoordinator.managedSessionNameToKill(for: paneId, status: $0) }
            : nil

        tmuxCoordinator.clearRuntimeState(for: paneId)
        reconnectCoordinator.removePane(paneId)
        richPasteRuntimeStore.removePane(paneId)
        detachTerminalRegistration(for: paneId)
        titleStore.removePane(paneId)

        transportCoordinator.removePane(
            paneId,
            deletingResumableState: intent.deletesResumableSessionState,
            killingManagedTmuxSessionNamed: tmuxSessionToKill
        )
    }

    // MARK: - Pane State

    #if os(iOS)
    private func publishTerminalInputAvailability(for paneId: UUID) {
        let connectionState = sessionState.paneState(for: paneId)?.connectionState ?? .idle
        let terminal = terminalSurfaceStore.surface(for: paneId)

        // Routing must be enabled before the coordinator can preserve or
        // reacquire the responder at the connected boundary.
        terminal?.acceptsTerminalInput = connectionState.isConnected
        keyboardCoordinator.setPaneInputEligible(
            TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: connectionState,
                shouldRestoreOnReconnect: terminal?.shouldRestoreKeyboardFocusOnReconnect == true
            ),
            for: paneId
        )
    }
    #endif

    /// Update connection state for a pane
    func updatePaneState(_ paneId: UUID, connectionState: ConnectionState) {
        let clearedDisconnectReason = connectionState.isConnected
            && sessionState.paneState(for: paneId)?.disconnectReason != nil
        sessionState.updatePane(paneId, persist: clearedDisconnectReason) { paneState in
            paneState.connectionState = connectionState
            if connectionState.isConnected {
                paneState.disconnectReason = nil
                paneState.markConnectionEstablished()
            }
        }
        #if os(iOS)
        publishTerminalInputAvailability(for: paneId)
        #endif
        switch connectionState {
        case .connecting, .reconnecting:
            if sessionState.paneState(for: paneId)?.activeTransport != .eternalTerminal {
                setPaneTransport(.ssh, for: paneId)
            }
        case .disconnected, .failed:
            setPanePresentationOverrides(.empty, for: paneId)
            terminalSurfaceStore.surface(for: paneId)?.applyPresentationOverrides(.empty)
            if tmuxCoordinator.status(for: paneId) == .foreground {
                tmuxCoordinator.updateStatus(.background, for: paneId)
            }
        case .connected:
            dependencies.effects.recordSuccessfulConnection(
                paneId,
                sessionState.paneState(for: paneId)?.activeTransport.rawValue
                    ?? ShellTransport.ssh.rawValue
            )
        case .idle:
            break
        }
        reconnectCoordinator.connectionStateDidChange(for: paneId)
    }

    func handleConnectionFailure(
        for paneId: UUID,
        failure: TerminalConnectionFailure
    ) {
        let requiresUserAction = !failure.allowsAutomaticReconnectRetry
        if requiresUserAction, sessionState.paneState(for: paneId)?.disconnectReason != nil {
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = nil }
        }
        updatePaneState(paneId, connectionState: .failed(failure))
    }

    func handleShellEnd(for paneId: UUID, reason: TerminalShellEndReason) {
        handleShellEnd(for: paneId, reason: reason, ownership: nil)
    }

    private func handleShellEnd(
        for paneId: UUID,
        reason: TerminalShellEndReason,
        ownership: TerminalTransportEndOwnership?
    ) {
        guard let paneState = sessionState.paneState(for: paneId) else { return }

        switch reason {
        case .tmuxEnded(.managed):
            guard let tab = sessionState.tab(
                id: paneState.tabId,
                for: paneState.serverId
            ) else {
                return
            }
            closePane(tab: tab, paneId: paneId, intent: .remoteSessionEnded)
            return

        case .tmuxDetached(let ownership):
            if ownership == .managed {
                tmuxCoordinator.confirmManagedSession(for: paneId)
            }
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = .tmuxDetached }
            updatePaneState(paneId, connectionState: .disconnected)

        case .tmuxCreationFailed:
            tmuxCoordinator.clearAttachmentState(for: paneId)
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = nil }
            tmuxCoordinator.updateStatus(.unknown, for: paneId)
            updatePaneState(
                paneId,
                connectionState: .failed(.tmuxStartupFailed)
            )

        case .tmuxEnded(.external):
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = .externalTmuxEnded }
            updatePaneState(paneId, connectionState: .disconnected)

        case .transportEnded:
            sessionState.updatePane(paneId) { $0.disconnectReason = .transportEnded }
            updatePaneState(paneId, connectionState: .disconnected)
        }

        let transportCoordinator = transportCoordinator
        Task { [weak transportCoordinator] in
            switch ownership {
            case .ssh(let client, let shellId):
                await transportCoordinator?.unregisterSSHClient(
                    for: paneId,
                    ifOwnedBy: client,
                    shellId: shellId
                )
            case .eternalTerminal(let token):
                await transportCoordinator?.unregisterEternalTerminalRuntime(
                    for: paneId,
                    ifOwnedByToken: token
                )
            case nil:
                break
            }
        }
    }

    private var hasConnectedPanes: Bool {
        sessionState.hasConnectedPanes
    }

    func updatePaneWorkingDirectory(_ paneId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        setPaneWorkingDirectory(normalized, for: paneId)
    }

    func updatePaneTitle(_ paneId: UUID, rawTitle: String) {
        guard sessionState.containsPane(paneId) else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        setPaneTitle(title, for: paneId)
    }

    func setPaneTitleOverride(_ rawTitle: String?, for paneId: UUID) {
        guard sessionState.containsPane(paneId) else { return }
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titleStore.setOverride(title.isEmpty ? nil : title, for: paneId)
    }

    func handleTerminalZoom(_ action: TerminalZoomAction, for paneId: UUID) -> TerminalZoomResult? {
        guard sessionState.containsPane(paneId) else { return nil }

        let currentOverrides = sessionState.presentationOverrides(for: paneId)
        let overrides = currentOverrides.applyingZoom(action)
        guard overrides != currentOverrides else {
            return TerminalZoomResult(
                presentationOverrides: currentOverrides,
                effectiveFontSize: currentOverrides.resolvedFontSize()
            )
        }
        setPanePresentationOverrides(overrides, for: paneId)
        sessionState.requestPersistence()
        terminalSurfaceStore.surface(for: paneId)?.applyPresentationOverrides(overrides)
        return TerminalZoomResult(
            presentationOverrides: overrides,
            effectiveFontSize: overrides.resolvedFontSize()
        )
    }

}

#if DEBUG
extension TerminalTabManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        let allPaneIds = sessionState.paneIds
            .union(transportCoordinator.ownedPaneIds)
        tmuxCoordinator.resetRuntimeState(for: allPaneIds)
        sessionState.resetForTesting()
        presentationState.reset()
        titleStore.reset()
        richPasteRuntimeStore.removeAll()
        #if os(iOS)
        keyboardCoordinator.setActivePane(nil)
        keyboardCoordinator.setViewActive(false)
        #endif
        drainTerminalSurfaces()
        reconnectCoordinator.reset()
        tabOpenAttemptsByServer.removeAll()
        await transportCoordinator.resetForTesting()
    }
}
#endif
