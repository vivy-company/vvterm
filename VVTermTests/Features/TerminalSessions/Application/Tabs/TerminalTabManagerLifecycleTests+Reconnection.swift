import Foundation
import Combine
import Testing
@testable import VVTerm

extension TerminalTabManagerLifecycleTests {
    @Suite(.serialized)
    @MainActor
    struct Reconnection: TerminalTabManagerTestSupport {
        @Test
        func reconnectClearsMoshFallbackDiagnostics() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Fallback")
                installTab(tab, in: manager, connectionState: .connected)
                manager.sessionState.updatePane(tab.rootPaneId) {
                    $0.transportState = .sshFallback(
                        reason: .udpTimeout,
                        diagnostics: .make(
                        reason: .udpTimeout,
                        events: [],
                        appContext: .init(version: "test", platform: "test")
                        )
                    )
                }
    
                manager.clearMoshFallbackDiagnostics(for: tab.rootPaneId)
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.activeTransport == .sshFallback)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackReason == .udpTimeout)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackDiagnostics == nil)
    
                manager.updatePaneState(tab.rootPaneId, connectionState: .reconnecting(attempt: 1))
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.activeTransport == .ssh)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackReason == nil)
            }
        }
    
        @Test
        func reconnectGenerationCreatesExactlyOneManagerOwnedReplacement() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Wake recovery")
                installTab(tab, in: manager, connectionState: .connected)
                manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
                manager.reconnectCoordinator.receiveApplicationActivity(true)
                let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
                let recoveryGeneration = UUID()
    
                #expect(manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: false,
                    generation: recoveryGeneration,
                    replacingCurrent: true
                ))
                #expect(!manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: false,
                    generation: recoveryGeneration,
                    replacingCurrent: true
                ))
                #expect(await waitUntil {
                    manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .connecting
                })
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState.isConnecting == true)
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        != originalTerminalGeneration
                )
    
                manager.updatePaneState(tab.rootPaneId, connectionState: .connected)
                #expect(manager.reconnectCoordinator.attempt(for: tab.rootPaneId) == nil)
            }
        }
    
        #if os(iOS)
        @Test
        func offlineReconnectWaitsWithoutStartingThenStartsExactlyOnceWhenReady() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Offline recovery")
                installTab(tab, in: manager, connectionState: .connected)
                manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
                let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
                manager.reconnectCoordinator.receiveNetworkReadiness(.unavailable)
    
                #expect(manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: false,
                    generation: UUID(),
                    replacingCurrent: false
                ))
                #expect(!manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: false,
                    generation: UUID(),
                    replacingCurrent: false
                ))
                #expect(await waitUntil {
                    manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
                })
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        == originalTerminalGeneration
                )
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
    
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
                #expect(await waitUntil {
                    manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .connecting
                })
                let replacementGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
                #expect(replacementGeneration != originalTerminalGeneration)
    
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
                await Task.yield()
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        == replacementGeneration
                )
            }
        }
    
        @Test
        func networkDropAfterReconnectIsQueuedWaitsForReady() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Mid-cleanup network loss")
                installTab(tab, in: manager, connectionState: .connected)
                manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
                let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
    
                #expect(manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: false,
                    generation: UUID(),
                    replacingCurrent: true
                ))
                manager.reconnectCoordinator.receiveNetworkReadiness(.unavailable)
    
                #expect(await waitUntil {
                    manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
                })
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        == originalTerminalGeneration
                )
    
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
                #expect(await waitUntil {
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        != originalTerminalGeneration
                })
                let replacementGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
                await Task.yield()
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        == replacementGeneration
                )
            }
        }
        #endif
    
        @Test
        func reconnectDetachesEternalTerminalOwnerBeforeReplacementStarts() async {
            await withCleanManager { manager in
                let server = makeServer(connectionMode: .eternalTerminal)
                let tab = TerminalTab(serverId: server.id, title: "ET recovery")
                installTab(tab, in: manager, connectionState: .connected)
                let credentials = ServerCredentials(serverId: server.id)
                let oldRuntime = manager.transportCoordinator.eternalTerminalRuntime(
                    for: tab.rootPaneId,
                    server: server,
                    credentials: credentials
                )
    
                #expect(manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: false,
                    generation: UUID(),
                    replacingCurrent: true
                ))
                #expect(await waitUntil {
                    !manager.transportCoordinator.isCurrentEternalTerminalRuntime(oldRuntime, for: tab.rootPaneId)
                })
    
                let replacement = manager.transportCoordinator.eternalTerminalRuntime(
                    for: tab.rootPaneId,
                    server: server,
                    credentials: credentials
                )
                await manager.transportCoordinator.unregisterEternalTerminalRuntime(
                    for: tab.rootPaneId,
                    ifOwnedBy: oldRuntime
                )
                #expect(manager.transportCoordinator.isCurrentEternalTerminalRuntime(replacement, for: tab.rootPaneId))
            }
        }
    
        #if os(macOS)
        @Test
        func macWakeSignalsCreateExactlyOneManagerOwnedReplacement() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Mac wake recovery")
                installTab(tab, in: manager, connectionState: .connected)
                let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
                #expect(await waitUntil { NetworkMonitor.shared.readiness == .ready })
    
                manager.reconnectCoordinator.receiveMacRecoverySignal(.sleep)
                manager.reconnectCoordinator.receiveMacRecoverySignal(.wake)
                manager.reconnectCoordinator.receiveMacRecoverySignal(.applicationActivated)
                manager.reconnectCoordinator.receiveMacRecoverySignal(.networkChanged(.ready))
    
                #expect(await waitUntil {
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        != originalTerminalGeneration
                })
                let replacementGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
    
                manager.reconnectCoordinator.receiveMacRecoverySignal(.wake)
                manager.reconnectCoordinator.receiveMacRecoverySignal(.applicationActivated)
                await Task.yield()
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        == replacementGeneration
                )
            }
        }
    
        @Test
        func macNetworkDropAfterReconnectIsQueuedWaitsForReady() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Mac mid-cleanup network loss")
                installTab(tab, in: manager, connectionState: .connected)
                manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
                let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                    for: tab.rootPaneId
                )
    
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
                let recoveryGeneration = UUID()
    
                #expect(manager.reconnectCoordinator.request(
                    for: tab.rootPaneId,
                    requiresReadyNetwork: true,
                    generation: recoveryGeneration,
                    replacingCurrent: true
                ))
                manager.reconnectCoordinator.receiveNetworkReadiness(.unavailable)
    
                #expect(await waitUntil {
                    manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
                })
                #expect(
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        == originalTerminalGeneration
                )
    
                manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
                #expect(await waitUntil {
                    manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                        != originalTerminalGeneration
                })
            }
        }
        #endif
    
        @Test
        func terminalZoomOnlyChangesRequestedPaneOverride() async {
            let defaults = UserDefaults.standard
            let previousFontSize = defaults.object(forKey: TerminalDefaults.fontSizeKey)
            defaults.set(12.0, forKey: TerminalDefaults.fontSizeKey)
            defer {
                if let previousFontSize {
                    defaults.set(previousFontSize, forKey: TerminalDefaults.fontSizeKey)
                } else {
                    defaults.removeObject(forKey: TerminalDefaults.fontSizeKey)
                }
            }
    
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Pane zoom")
                installTab(tab, in: manager, connectionState: .connected)
                let siblingPaneId = UUID()
                manager.sessionState.setPaneState(TerminalPaneState(
                    paneId: siblingPaneId,
                    tabId: tab.id,
                    serverId: tab.serverId
                ))
    
                let result = manager.handleTerminalZoom(.zoomIn, for: tab.rootPaneId)
    
                #expect(result?.effectiveFontSize == 13.0)
                #expect(manager.sessionState.presentationOverrides(for: tab.rootPaneId).fontSize == 13.0)
                #expect(manager.sessionState.presentationOverrides(for: siblingPaneId).isEmpty)
                #expect(defaults.double(forKey: TerminalDefaults.fontSizeKey) == 12.0)
            }
        }
    
        @Test
        func successfulMoshRegistrationReplacesFallbackDiagnostics() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Mosh recovery")
                installTab(tab, in: manager, connectionState: .connected)
                manager.sessionState.updatePane(tab.rootPaneId) {
                    $0.transportState = .sshFallback(
                        reason: .udpTimeout,
                        diagnostics: .make(
                        reason: .udpTimeout,
                        events: [],
                        appContext: .init(version: "test", platform: "test")
                        )
                    )
                }
    
                let client = SSHClient.testing()
                #expect(await startAndRegisterShell(
                    client,
                    paneId: tab.rootPaneId,
                    serverId: tab.serverId,
                    transportState: .mosh,
                    in: manager
                ))
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.activeTransport == .mosh)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackReason == nil)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackDiagnostics == nil)
            }
        }
    
    }
}
