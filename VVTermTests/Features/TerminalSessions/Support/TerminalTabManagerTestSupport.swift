import Foundation
import Combine
import Testing
@testable import VVTerm

actor TmuxAvailabilityGate {
    private var continuation: CheckedContinuation<RemoteTmuxAvailability, Never>?

    func waitForResolution() async -> RemoteTmuxAvailability {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if continuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return continuation != nil
    }

    func resolve(_ availability: RemoteTmuxAvailability) {
        continuation?.resume(returning: availability)
        continuation = nil
    }
}


@MainActor
protocol TerminalTabManagerTestSupport {}

extension TerminalTabManagerTestSupport {
    func makeServer(
        id: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .standard
    ) -> Server {
        Server(
            id: id,
            workspaceId: UUID(),
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    func withCleanManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTestComposition.makeManager()
        try await body(manager)
    }

    func withTmuxEnabled(
        _ body: @MainActor () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let key = "terminalTmuxEnabledDefault"
        let previousValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await body()
    }

    func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    func installTab(
        _ tab: TerminalTab,
        in manager: TerminalTabManager,
        connectionState: ConnectionState = .connecting
    ) {
        manager.sessionState.install(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ), select: true)
        manager.updatePaneState(tab.rootPaneId, connectionState: connectionState)
    }

    func startAndRegisterShell(
        _ client: SSHClient,
        shellId: UUID = UUID(),
        paneId: UUID,
        serverId: UUID,
        transportState: ShellTransportState = .ssh,
        in manager: TerminalTabManager
    ) async -> Bool {
        guard let startToken = manager.transportCoordinator.beginShellStart(for: paneId, client: client) else {
            return false
        }
        return await manager.transportCoordinator.registerSSHClient(
            client,
            shellId: shellId,
            startToken: startToken,
            for: paneId,
            serverId: serverId,
            transportState: transportState
        )
    }

}

