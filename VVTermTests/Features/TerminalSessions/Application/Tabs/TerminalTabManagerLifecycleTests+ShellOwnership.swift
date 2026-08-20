import Foundation
import Combine
import Testing
@testable import VVTerm

extension TerminalTabManagerLifecycleTests {
    @Suite(.serialized)
    @MainActor
    struct ShellOwnership: TerminalTabManagerTestSupport {
        @Test
        func staleExitCannotUnregisterReplacementShell() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Replacement shell")
                installTab(tab, in: manager)
                let oldClient = SSHClient.testing()
                let oldShellId = UUID()
    
                #expect(await startAndRegisterShell(
                    oldClient,
                    shellId: oldShellId,
                    paneId: tab.rootPaneId,
                    serverId: tab.serverId,
                    in: manager
                ))
                await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
    
                let replacementClient = SSHClient.testing()
                let replacementShellId = UUID()
                #expect(await startAndRegisterShell(
                    replacementClient,
                    shellId: replacementShellId,
                    paneId: tab.rootPaneId,
                    serverId: tab.serverId,
                    in: manager
                ))
    
                await manager.transportCoordinator.unregisterSSHClient(
                    for: tab.rootPaneId,
                    ifOwnedBy: oldClient,
                    shellId: oldShellId
                )
    
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.shellId == replacementShellId)
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.client === replacementClient)
            }
        }
    
        @Test
        func currentSurfaceExitCancelsPendingStartWithoutRemovingReplacement() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Pending surface exit")
                installTab(tab, in: manager)
                let exitedSurfaceClient = SSHClient.testing()
    
                guard let exitedStartToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: exitedSurfaceClient
                ), let exitedConnectionToken = manager.transportCoordinator.connectionOwnershipToken(for: tab.rootPaneId) else {
                    Issue.record("Expected the exiting surface to own a shell start")
                    return
                }
                #expect(exitedConnectionToken == exitedStartToken)
                #expect(manager.transportCoordinator.isCurrentShellOwner(
                    for: tab.rootPaneId,
                    client: exitedSurfaceClient,
                    startToken: exitedStartToken
                ))
    
                await manager.transportCoordinator.unregisterSSHClient(
                    for: tab.rootPaneId,
                    ifOwnedBy: exitedConnectionToken
                )
                #expect(!manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
    
                guard let replacementStartToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: exitedSurfaceClient
                ) else {
                    Issue.record("Expected a same-client replacement shell start")
                    return
                }
    
                await manager.transportCoordinator.unregisterSSHClient(
                    for: tab.rootPaneId,
                    ifOwnedBy: exitedConnectionToken
                )
                #expect(manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
                #expect(manager.transportCoordinator.isCurrentShellOwner(
                    for: tab.rootPaneId,
                    client: exitedSurfaceClient,
                    startToken: replacementStartToken
                ))
            }
        }
    
        @Test
        func staleRegistrationFromDifferentClientDoesNotReplacePendingStart() async {
            await withCleanManager { manager in
                let serverId = UUID()
                let tab = TerminalTab(serverId: serverId, title: "Pending")
                installTab(tab, in: manager)
    
                let activeClient = SSHClient.testing()
                let staleClient = SSHClient.testing()
                guard let activeStartToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: activeClient
                ) else {
                    Issue.record("Expected active shell start")
                    return
                }
    
                #expect(!(await manager.transportCoordinator.registerSSHClient(
                    staleClient,
                    shellId: UUID(),
                    startToken: activeStartToken,
                    for: tab.rootPaneId,
                    serverId: serverId
                )))
    
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)
                #expect(manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
    
                manager.transportCoordinator.finishShellStart(
                    for: tab.rootPaneId,
                    client: staleClient,
                    startToken: activeStartToken
                )
                #expect(manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
    
                manager.transportCoordinator.finishShellStart(
                    for: tab.rootPaneId,
                    client: activeClient,
                    startToken: activeStartToken
                )
                #expect(!manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
            }
        }
    
        @Test
        func unregisterWithoutShellClearsPendingStart() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Pending")
                installTab(tab, in: manager)
    
                let firstClient = SSHClient.testing()
                #expect(manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: firstClient) != nil)
    
                await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
    
                #expect(!manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)
    
                let nextClient = SSHClient.testing()
                guard let nextStartToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: nextClient
                ) else {
                    Issue.record("Expected replacement shell start")
                    return
                }
                manager.transportCoordinator.finishShellStart(
                    for: tab.rootPaneId,
                    client: nextClient,
                    startToken: nextStartToken
                )
            }
        }
    
        @Test
        func unregisterPendingShellStartCancelsItsTmuxPrompt() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Pending prompt")
                installTab(tab, in: manager)
                let client = SSHClient.testing()
                guard let startToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected pending shell start")
                    return
                }
    
                let selection = Task { @MainActor in
                    await manager.tmuxCoordinator.requestSelection(
                        requestId: startToken.id,
                        paneId: tab.rootPaneId,
                        serverId: tab.serverId,
                        availableSessions: []
                    )
                }
                guard await waitUntil({
                    manager.tmuxCoordinator.hasPendingPrompt(requestId: startToken.id)
                }) else {
                    Issue.record("Pending tmux prompt was not enqueued")
                    selection.cancel()
                    return
                }
    
                await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
    
                let promptWasCancelled = await waitUntil({
                    !manager.tmuxCoordinator.hasPendingPrompt(requestId: startToken.id)
                        && manager.tmuxCoordinator.attachPrompt == nil
                })
                #expect(promptWasCancelled)
                if !promptWasCancelled {
                    selection.cancel()
                }
                #expect(await selection.value == .skipTmux)
            }
        }
    
        @Test
        func onlyCurrentPaneClientCanContinueConnecting() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Pending")
                installTab(tab, in: manager)
                let activeClient = SSHClient.testing()
                let staleClient = SSHClient.testing()
    
                guard let activeStartToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: activeClient
                ) else {
                    Issue.record("Expected active shell start")
                    return
                }
                #expect(manager.transportCoordinator.isCurrentShellOwner(
                    for: tab.rootPaneId,
                    client: activeClient,
                    startToken: activeStartToken
                ))
                #expect(!manager.transportCoordinator.isCurrentShellOwner(
                    for: tab.rootPaneId,
                    client: staleClient,
                    startToken: activeStartToken
                ))
    
                await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
    
                #expect(!manager.transportCoordinator.isCurrentShellOwner(
                    for: tab.rootPaneId,
                    client: activeClient,
                    startToken: activeStartToken
                ))
            }
        }
    
        @Test
        func shellStartFailsWhenPaneIsMissing() async {
            await withCleanManager { manager in
                let missingPaneId = UUID()
    
                #expect(manager.transportCoordinator.beginShellStart(for: missingPaneId, client: SSHClient.testing()) == nil)
                #expect(!manager.transportCoordinator.isTransportStartInFlight(for: missingPaneId))
            }
        }
    
        @Test
        func disconnectServerLeavesOtherServerTabsAndShellsConnected() async {
            await withCleanManager { manager in
                let firstTab = TerminalTab(serverId: UUID(), title: "First")
                let secondTab = TerminalTab(serverId: UUID(), title: "Second")
                installTab(firstTab, in: manager)
                installTab(secondTab, in: manager)
    
                let firstClient = SSHClient.testing()
                let secondClient = SSHClient.testing()
                #expect(await startAndRegisterShell(
                    firstClient,
                    paneId: firstTab.rootPaneId,
                    serverId: firstTab.serverId,
                    in: manager
                ))
                #expect(await startAndRegisterShell(
                    secondClient,
                    paneId: secondTab.rootPaneId,
                    serverId: secondTab.serverId,
                    in: manager
                ))
                manager.updatePaneState(firstTab.rootPaneId, connectionState: .connected)
                manager.updatePaneState(secondTab.rootPaneId, connectionState: .connected)
    
                manager.disconnectServer(firstTab.serverId)
    
                #expect(manager.sessionState.tabs(for: firstTab.serverId).isEmpty)
                #expect(manager.sessionState.paneState(for: firstTab.rootPaneId) == nil)
                #expect(manager.transportCoordinator.activeSSHRoute(for: firstTab.rootPaneId) == nil)
                #expect(manager.sessionState.tabs(for: secondTab.serverId) == [secondTab])
                #expect(manager.sessionState.paneState(for: secondTab.rootPaneId)?.connectionState == .connected)
                #expect(manager.transportCoordinator.activeSSHRoute(for: secondTab.rootPaneId) != nil)
            }
        }
    
        @Test
        func staleShellOnSharedClientDoesNotDisconnectSiblingPane() async {
            await withCleanManager { manager in
                let siblingTab = TerminalTab(serverId: UUID(), title: "Sibling")
                let pendingTab = TerminalTab(serverId: UUID(), title: "Pending")
                installTab(siblingTab, in: manager)
                installTab(pendingTab, in: manager)
    
                let sharedClient = SSHClient.testing()
                #expect(await startAndRegisterShell(
                    sharedClient,
                    paneId: siblingTab.rootPaneId,
                    serverId: siblingTab.serverId,
                    in: manager
                ))
    
                let pendingClient = SSHClient.testing()
                guard let pendingStartToken = manager.transportCoordinator.beginShellStart(
                    for: pendingTab.rootPaneId,
                    client: pendingClient
                ) else {
                    Issue.record("Expected pending shell start")
                    return
                }
                #expect(!(await manager.transportCoordinator.registerSSHClient(
                    sharedClient,
                    shellId: UUID(),
                    startToken: pendingStartToken,
                    for: pendingTab.rootPaneId,
                    serverId: pendingTab.serverId
                )))
    
                #expect(!(await sharedClient.isAborted))
                #expect(manager.transportCoordinator.activeSSHRoute(for: siblingTab.rootPaneId)?.client === sharedClient)
                #expect(manager.transportCoordinator.isCurrentShellOwner(
                    for: pendingTab.rootPaneId,
                    client: pendingClient,
                    startToken: pendingStartToken
                ))
            }
        }
    
        @Test
        func shellExitLifecycleDisconnectsPaneAndClearsRegistration() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Shell Exit")
                installTab(tab, in: manager)
    
                let client = SSHClient.testing()
                #expect(await startAndRegisterShell(
                    client,
                    paneId: tab.rootPaneId,
                    serverId: tab.serverId,
                    in: manager
                ))
                manager.updatePaneState(tab.rootPaneId, connectionState: .connected)
    
                manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
                await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)
                #expect(!TerminalConnectionStartPolicy.shouldStart(connectionState: .disconnected))
            }
        }
    
    }
}
