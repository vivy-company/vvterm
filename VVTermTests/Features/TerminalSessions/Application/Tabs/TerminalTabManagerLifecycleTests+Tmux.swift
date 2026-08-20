import Foundation
import Combine
import Testing
@testable import VVTerm

extension TerminalTabManagerLifecycleTests {
    @Suite(.serialized)
    @MainActor
    struct Tmux: TerminalTabManagerTestSupport {
        @Test
        func managedTmuxEndClosesItsLastPaneAndTab() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Managed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_test",
                    ownership: .managed
                )
                manager.tmuxCoordinator.updateStatus(.foreground, for: tab.rootPaneId)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxEnded(.managed))
    
                #expect(manager.sessionState.tabs(for: tab.serverId).isEmpty)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId) == nil)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
            }
        }
    
        @Test
        func managedTmuxEndClosesOnlyItsPaneInSplitTab() async {
            await withCleanManager { manager in
                let secondPaneId = UUID()
                var tab = TerminalTab(serverId: UUID(), title: "Split tmux")
                tab.layout = .split(.init(
                    direction: .horizontal,
                    ratio: 0.5,
                    left: .leaf(paneId: tab.rootPaneId),
                    right: .leaf(paneId: secondPaneId)
                ))
                installTab(tab, in: manager, connectionState: .connected)
                manager.sessionState.setPaneState(TerminalPaneState(
                    paneId: secondPaneId,
                    tabId: tab.id,
                    serverId: tab.serverId
                ))
                manager.tmuxCoordinator.setAttachment(
                    for: secondPaneId,
                    sessionName: "vvterm_second",
                    ownership: .managed
                )
                manager.tmuxCoordinator.updateStatus(.background, for: secondPaneId)
    
                manager.handleShellEnd(for: secondPaneId, reason: .tmuxEnded(.managed))
    
                let remainingTab = manager.sessionState.tabs(for: tab.serverId).first
                #expect(remainingTab?.allPaneIds == [tab.rootPaneId])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId) != nil)
                #expect(manager.sessionState.paneState(for: secondPaneId) == nil)
            }
        }
    
        @Test
        func managedTmuxDetachPreservesPaneAndSuppressesAutomaticReconnect() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Detached tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_test",
                    ownership: .managed
                )
                manager.tmuxCoordinator.updateStatus(.foreground, for: tab.rootPaneId)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxDetached(.managed))
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .tmuxDetached)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == false)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId)?.sessionName == "vvterm_test")
                #expect(manager.tmuxCoordinator.hasConfirmedManagedSession(for: tab.rootPaneId))
            }
        }
    
        @Test
        func disconnectedTmuxProbePreservesConfirmedAttachmentInsteadOfReportingMissing() async {
            await withTmuxEnabled {
                await withCleanManager { manager in
                    let tab = TerminalTab(serverId: UUID(), title: "Long-idle tmux reconnect")
                    installTab(tab, in: manager, connectionState: .disconnected)
                    manager.tmuxCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
                    let disconnectedClient = SSHClient.testing()
                    guard let startToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: disconnectedClient
                    ) else {
                        Issue.record("Expected disconnected shell start")
                        return
                    }
    
                    do {
                        _ = try await manager.tmuxCoordinator.startupPlan(
                            for: tab.rootPaneId,
                            serverId: tab.serverId,
                            client: disconnectedClient,
                            startToken: startToken,
                            availabilityResolver: {
                                .indeterminate(.disconnected)
                            }
                        )
                        Issue.record("An indeterminate tmux probe should retry the connection")
                    } catch {
                        #expect(error is SSHError)
                    }
    
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                    #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    ))
                    #expect(manager.tmuxCoordinator.attachPrompt == nil)
    
                    manager.transportCoordinator.finishShellStart(
                        for: tab.rootPaneId,
                        client: disconnectedClient,
                        startToken: startToken
                    )
                }
            }
        }
    
        @Test
        func explicitMissingTmuxProbeClearsAttachmentAndReportsMissing() async {
            await withTmuxEnabled {
                await withCleanManager { manager in
                    let tab = TerminalTab(serverId: UUID(), title: "Confirmed missing tmux")
                    installTab(tab, in: manager, connectionState: .disconnected)
                    manager.tmuxCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
                    let client = SSHClient.testing()
                    guard let startToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: client
                    ) else {
                        Issue.record("Expected shell start")
                        return
                    }
                    _ = try? await manager.tmuxCoordinator.startupPlan(
                        for: tab.rootPaneId,
                        serverId: tab.serverId,
                        client: client,
                        startToken: startToken,
                        availabilityResolver: { .confirmedMissing }
                    )
    
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .missing)
                    #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
    
                    manager.transportCoordinator.finishShellStart(
                        for: tab.rootPaneId,
                        client: client,
                        startToken: startToken
                    )
                }
            }
        }
    
        @Test
        func staleMissingTmuxProbeCannotOverwriteReplacementOwner() async {
            await withTmuxEnabled {
                await withCleanManager { manager in
                    let tab = TerminalTab(serverId: UUID(), title: "Stale tmux probe")
                    installTab(tab, in: manager, connectionState: .disconnected)
                    manager.tmuxCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
                    let client = SSHClient.testing()
                    let gate = TmuxAvailabilityGate()
                    guard let staleStartToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: client
                    ) else {
                        Issue.record("Expected stale shell start")
                        return
                    }
    
                    let stalePlan = Task { @MainActor in
                        do {
                            _ = try await manager.tmuxCoordinator.startupPlan(
                                for: tab.rootPaneId,
                                serverId: tab.serverId,
                                client: client,
                                startToken: staleStartToken,
                                availabilityResolver: { await gate.waitForResolution() }
                            )
                            return false
                        } catch is CancellationError {
                            return true
                        } catch {
                            Issue.record("Unexpected stale probe error: \(error)")
                            return false
                        }
                    }
    
                    #expect(await gate.waitUntilBlocked())
                    manager.transportCoordinator.finishShellStart(
                        for: tab.rootPaneId,
                        client: client,
                        startToken: staleStartToken
                    )
                    guard let replacementStartToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: client
                    ) else {
                        Issue.record("Expected replacement shell start")
                        return
                    }
                    await gate.resolve(.confirmedMissing)
    
                    #expect(await stalePlan.value)
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                    #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    ))
    
                    manager.transportCoordinator.finishShellStart(
                        for: tab.rootPaneId,
                        client: client,
                        startToken: replacementStartToken
                    )
                }
            }
        }
    
        @Test
        func cancelledTmuxProbeCannotPublishMissingForCurrentOwner() async {
            await withTmuxEnabled {
                await withCleanManager { manager in
                    let tab = TerminalTab(serverId: UUID(), title: "Cancelled tmux probe")
                    installTab(tab, in: manager, connectionState: .disconnected)
                    manager.tmuxCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
                    let client = SSHClient.testing()
                    let gate = TmuxAvailabilityGate()
                    guard let startToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: client
                    ) else {
                        Issue.record("Expected shell start")
                        return
                    }
    
                    let cancelledPlan = Task { @MainActor in
                        do {
                            _ = try await manager.tmuxCoordinator.startupPlan(
                                for: tab.rootPaneId,
                                serverId: tab.serverId,
                                client: client,
                                startToken: startToken,
                                availabilityResolver: { await gate.waitForResolution() }
                            )
                            return false
                        } catch is CancellationError {
                            return true
                        } catch {
                            Issue.record("Unexpected cancelled probe error: \(error)")
                            return false
                        }
                    }
    
                    #expect(await gate.waitUntilBlocked())
                    cancelledPlan.cancel()
                    await gate.resolve(.confirmedMissing)
    
                    #expect(await cancelledPlan.value)
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                    #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                        sessionName: "vvterm_existing",
                        ownership: .managed,
                        managedSessionConfirmed: true
                    ))
    
                    manager.transportCoordinator.finishShellStart(
                        for: tab.rootPaneId,
                        client: client,
                        startToken: startToken
                    )
                }
            }
        }
    
        @Test
        func cancelledTmuxPromptCannotResolveReplacementPromptForSamePane() async {
            let coordinator = TerminalTmuxSessionCoordinator()
            let paneId = UUID()
            let serverId = UUID()
            let staleRequestId = UUID()
            let replacementRequestId = UUID()
    
            let staleSelection = Task { @MainActor in
                await coordinator.requestSelection(
                    requestId: staleRequestId,
                    paneId: paneId,
                    serverId: serverId,
                    availableSessions: []
                )
            }
            guard await waitUntil({
                coordinator.hasPendingPrompt(requestId: staleRequestId)
            }) else {
                Issue.record("Stale tmux prompt was not enqueued")
                staleSelection.cancel()
                return
            }
    
            let replacementSelection = Task { @MainActor in
                await coordinator.requestSelection(
                    requestId: replacementRequestId,
                    paneId: paneId,
                    serverId: serverId,
                    availableSessions: []
                )
            }
            guard await waitUntil({
                coordinator.hasPendingPrompt(requestId: replacementRequestId)
            }) else {
                Issue.record("Replacement tmux prompt was not enqueued")
                staleSelection.cancel()
                replacementSelection.cancel()
                return
            }
    
            staleSelection.cancel()
            #expect(await waitUntil({
                coordinator.attachPrompt?.id == replacementRequestId
                    && !coordinator.hasPendingPrompt(requestId: staleRequestId)
            }))
    
            coordinator.resolvePrompt(
                requestId: replacementRequestId,
                selection: .createManaged
            )
    
            #expect(await staleSelection.value == .skipTmux)
            #expect(await replacementSelection.value == .createManaged)
        }
    
        @Test
        func managedReattachRequiresExplicitSessionConfirmation() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_test",
                    ownership: .managed
                )
    
                #expect(!manager.tmuxCoordinator.shouldReattachManagedSession(for: tab.rootPaneId))
    
                manager.tmuxCoordinator.confirmManagedSession(for: tab.rootPaneId)
    
                #expect(manager.tmuxCoordinator.shouldReattachManagedSession(for: tab.rootPaneId))
            }
        }
    
        @Test
        func managedSessionConfirmationRoundTripsWithoutPromotingUnconfirmedSessions() async {
            await withCleanManager { manager in
                let confirmedTab = TerminalTab(serverId: UUID(), title: "Confirmed tmux")
                let unconfirmedTab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
                installTab(confirmedTab, in: manager, connectionState: .connected)
                installTab(unconfirmedTab, in: manager, connectionState: .connected)
    
                manager.tmuxCoordinator.setAttachment(
                    for: confirmedTab.rootPaneId,
                    sessionName: "vvterm_confirmed",
                    ownership: .managed,
                    managedSessionConfirmed: true
                )
                manager.tmuxCoordinator.setAttachment(
                    for: unconfirmedTab.rootPaneId,
                    sessionName: "vvterm_unconfirmed",
                    ownership: .managed
                )
    
                manager.sessionState.persistAndRestoreSnapshotForTesting()
    
                #expect(manager.tmuxCoordinator.shouldReattachManagedSession(for: confirmedTab.rootPaneId))
                #expect(!manager.tmuxCoordinator.shouldReattachManagedSession(for: unconfirmedTab.rootPaneId))
            }
        }
    
        @Test
        func managedTmuxCreationFailurePreservesPaneAndClearsUnprovenAttachment() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Failed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_test",
                    ownership: .managed
                )
                manager.tmuxCoordinator.updateStatus(.foreground, for: tab.rootPaneId)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxCreationFailed)
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(
                    manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState
                        == .failed(.tmuxStartupFailed)
                )
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .unknown)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
            }
        }
    
        @Test
        func successfulTmuxInstallTriggersExplicitReconnect() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Installed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.sessionState.updatePane(tab.rootPaneId) { $0.disconnectReason = .tmuxDetached }
                var reconnectRequested = false
    
                manager.tmuxCoordinator.completeInstall(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_installed",
                    onInstalled: { reconnectRequested = true }
                )
    
                #expect(reconnectRequested)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId)?.sessionName == "vvterm_installed")
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId)?.ownership == .managed)
            }
        }
    
        @Test
        func transportEndPreservesPaneAndAllowsAutomaticReconnect() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Dropped transport")
                installTab(tab, in: manager, connectionState: .connected)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == true)
            }
        }
    
        @Test
        func transientReconnectFailurePreservesAutomaticRetryEligibility() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Transient retry")
                installTab(tab, in: manager, connectionState: .connected)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
                manager.updatePaneState(
                    tab.rootPaneId,
                    connectionState: .reconnecting(attempt: 1)
                )
                manager.handleConnectionFailure(
                    for: tab.rootPaneId,
                    failure: .transport(SSHError.timeout)
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
                guard case .failed = manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState else {
                    Issue.record("Expected a failed retry state")
                    return
                }
            }
        }
    
        @Test
        func unclassifiedReconnectFailurePreservesAutomaticRetryEligibility() async {
            await withCleanManager { manager in
                struct UnclassifiedReconnectError: LocalizedError {
                    var errorDescription: String? { "Temporary transport failure" }
                }
    
                let tab = TerminalTab(serverId: UUID(), title: "Unclassified retry")
                installTab(tab, in: manager, connectionState: .connected)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
                manager.updatePaneState(
                    tab.rootPaneId,
                    connectionState: .reconnecting(attempt: 1)
                )
                manager.handleConnectionFailure(
                    for: tab.rootPaneId,
                    failure: .transport(UnclassifiedReconnectError())
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
                guard case .failed = manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState else {
                    Issue.record("Expected a failed retry state")
                    return
                }
            }
        }
    
        @Test
        func userActionFailureStopsAutomaticRetry() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Manual recovery")
                installTab(tab, in: manager, connectionState: .connected)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
                manager.handleConnectionFailure(
                    for: tab.rootPaneId,
                    failure: .transport(SSHError.authenticationFailed)
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
                guard case .failed = manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState else {
                    Issue.record("Expected a failed authentication state")
                    return
                }
            }
        }
    
        @Test
        func staleShellEndCannotDisconnectReplacementShell() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Replacement")
                installTab(tab, in: manager, connectionState: .connected)
                let activeClient = SSHClient.testing()
                let activeShellId = UUID()
                #expect(await startAndRegisterShell(
                    activeClient,
                    shellId: activeShellId,
                    paneId: tab.rootPaneId,
                    serverId: tab.serverId,
                    in: manager
                ))
    
                manager.transportCoordinator.handleShellEnd(
                    for: tab.rootPaneId,
                    client: SSHClient.testing(),
                    shellId: UUID(),
                    reason: .transportEnded
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .connected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.shellId == activeShellId)
            }
        }
    }
}
