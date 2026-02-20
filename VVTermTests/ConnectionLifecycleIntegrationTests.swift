import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ConnectionLifecycleIntegrationTests {
    private func makeServer(
        id: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .cloudflare
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceId,
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    private func makeCredentials(serverId: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverId,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async throws -> Void
    ) async rethrows {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    @Test
    func connectionManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Session A",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: session.id, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: staleClient)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: session.id))
        }
    }

    @Test
    func connectionManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Session B",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: firstClient))

            await manager.unregisterSSHClient(for: session.id)
            #expect(!manager.isShellStartInFlight(for: session.id))
            #expect(manager.shellId(for: session.id) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: nextClient))
            manager.finishShellStart(for: session.id, client: nextClient)
        }
    }

    @Test
    func tabManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let tabId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: tabId,
                serverId: serverId
            )

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: paneId, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: paneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: paneId) == nil)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: staleClient)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: paneId))
        }
    }

    @Test
    func tabManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: firstClient))

            await manager.unregisterSSHClient(for: paneId)
            #expect(!manager.isShellStartInFlight(for: paneId))
            #expect(manager.shellId(for: paneId) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: nextClient))
            manager.finishShellStart(for: paneId, client: nextClient)
        }
    }

    @Test
    func sessionWrapperUsesIsolatedSSHClientForSameServer() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let existingSession = ConnectionSession(
                serverId: server.id,
                title: "Existing",
                connectionState: .connected
            )
            manager.sessions = [existingSession]

            let sharedClient = SSHClient()
            manager.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                for: existingSession.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            let newSession = ConnectionSession(
                serverId: server.id,
                title: "New",
                connectionState: .connecting
            )
            let wrapper = SSHTerminalWrapper(
                session: newSession,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {},
                onReady: {}
            )

            let coordinator = wrapper.makeCoordinator()
            #expect(ObjectIdentifier(coordinator.sshClient) != ObjectIdentifier(sharedClient))
        }
    }

    @Test
    func sessionWrapperDoesNotReuseActiveSSHClientForCloudflare() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .cloudflare)
            let existingSession = ConnectionSession(
                serverId: server.id,
                title: "Existing",
                connectionState: .connected
            )
            manager.sessions = [existingSession]

            let activeClient = SSHClient()
            manager.registerSSHClient(
                activeClient,
                shellId: UUID(),
                for: existingSession.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            let newSession = ConnectionSession(
                serverId: server.id,
                title: "New",
                connectionState: .connecting
            )
            let wrapper = SSHTerminalWrapper(
                session: newSession,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {},
                onReady: {}
            )

            let coordinator = wrapper.makeCoordinator()
            #expect(ObjectIdentifier(coordinator.sshClient) != ObjectIdentifier(activeClient))
        }
    }

    @Test
    func sessionWrapperDoesNotReuseInFlightSSHClientForSameServer() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .cloudflare)
            let connectingSession = ConnectionSession(
                serverId: server.id,
                title: "Connecting",
                connectionState: .connecting
            )
            manager.sessions = [connectingSession]

            let inFlightClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: connectingSession.id, client: inFlightClient))

            let newSession = ConnectionSession(
                serverId: server.id,
                title: "New",
                connectionState: .connecting
            )
            let wrapper = SSHTerminalWrapper(
                session: newSession,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {},
                onReady: {}
            )

            let coordinator = wrapper.makeCoordinator()
            #expect(ObjectIdentifier(coordinator.sshClient) != ObjectIdentifier(inFlightClient))
        }
    }

    @Test
    func paneWrapperUsesIsolatedSSHClientForSameServer() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            let sharedClient = SSHClient()
            manager.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            let newPaneId = UUID()
            let wrapper = SSHTerminalPaneWrapper(
                paneId: newPaneId,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                isActive: true,
                onProcessExit: {},
                onReady: {}
            )

            let coordinator = wrapper.makeCoordinator()
            #expect(ObjectIdentifier(coordinator.sshClient) != ObjectIdentifier(sharedClient))
        }
    }

    @Test
    func paneWrapperDoesNotReuseActiveSSHClientForCloudflare() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .cloudflare)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            let activeClient = SSHClient()
            manager.registerSSHClient(
                activeClient,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            let wrapper = SSHTerminalPaneWrapper(
                paneId: UUID(),
                server: server,
                credentials: makeCredentials(serverId: server.id),
                isActive: true,
                onProcessExit: {},
                onReady: {}
            )

            let coordinator = wrapper.makeCoordinator()
            #expect(ObjectIdentifier(coordinator.sshClient) != ObjectIdentifier(activeClient))
        }
    }

    @Test
    func paneWrapperDoesNotReuseInFlightSSHClientForSameServer() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .cloudflare)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            let inFlightClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: tab.rootPaneId, client: inFlightClient))

            let wrapper = SSHTerminalPaneWrapper(
                paneId: UUID(),
                server: server,
                credentials: makeCredentials(serverId: server.id),
                isActive: true,
                onProcessExit: {},
                onReady: {}
            )

            let coordinator = wrapper.makeCoordinator()
            #expect(ObjectIdentifier(coordinator.sshClient) != ObjectIdentifier(inFlightClient))
        }
    }

    @Test
    func splitPaneUsesLatestTabStateWhenViewTabIsStale() async {
        await withCleanTabManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)

            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            guard let firstSplitPane = manager.splitHorizontal(tab: tab, paneId: tab.rootPaneId) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            // Intentionally pass a stale snapshot (the original `tab` value) to simulate
            // view-state lag while still targeting a pane created by the first split.
            guard let secondSplitPane = manager.splitVertical(tab: tab, paneId: firstSplitPane) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.tabs(for: server.id).first else {
                Issue.record("Expected tab to exist after split")
                return
            }

            let paneIds = Set(latestTab.allPaneIds)
            #expect(paneIds.contains(tab.rootPaneId))
            #expect(paneIds.contains(firstSplitPane))
            #expect(paneIds.contains(secondSplitPane))
            #expect(paneIds.count == 3)
        }
    }
}
