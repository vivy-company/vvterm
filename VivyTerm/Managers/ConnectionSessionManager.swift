import Foundation
import Combine
import os.log

// MARK: - Connection Session Manager

@MainActor
final class ConnectionSessionManager: ObservableObject {
    static let shared = ConnectionSessionManager()

    @Published var sessions: [ConnectionSession] = []
    @Published var selectedSessionId: UUID?

    /// The server we're currently connected to (persists even when all terminals closed)
    /// Only cleared when user explicitly disconnects
    @Published var connectedServerId: UUID?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ConnectionSession")

    /// SSH clients indexed by session ID for stats collection and command execution
    private var sshClients: [UUID: SSHClient] = [:]

    /// Terminal views indexed by session ID for voice input and other external interactions
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]

    /// Shell cancel handlers indexed by session ID - called before closing to cancel async tasks
    private var shellCancelHandlers: [UUID: () -> Void] = [:]

    private init() {}

    // MARK: - Session Management

    var selectedSession: ConnectionSession? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeSessions: [ConnectionSession] {
        sessions.filter { $0.connectionState.isConnected }
    }

    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        return activeSessions.count < FreeTierLimits.maxTabs
    }

    // MARK: - Open Connection

    /// Opens a connection to a server
    /// - Parameters:
    ///   - server: The server to connect to
    ///   - forceNew: If true, always creates a new tab even if one exists for this server
    func openConnection(to server: Server, forceNew: Bool = false) async throws -> ConnectionSession {
        guard canOpenNewTab else {
            throw VivyTermError.proRequired("Upgrade to Pro for multiple connections")
        }

        // Check if already have a session for this server (unless forcing new)
        if !forceNew, let existingSession = sessions.first(where: { $0.serverId == server.id && $0.connectionState.isConnected }) {
            selectedSessionId = existingSession.id
            return existingSession
        }

        // Create new session - actual SSH connection happens in SSHTerminalWrapper
        let session = ConnectionSession(
            serverId: server.id,
            title: server.name,
            connectionState: .connected  // Will connect when terminal view appears
        )

        sessions.append(session)
        selectedSessionId = session.id
        connectedServerId = server.id

        // Update server's last connected
        await ServerManager.shared.updateLastConnected(for: server)

        logger.info("Created session for \(server.name)")
        return session
    }

    // MARK: - Close Terminal

    /// Closes a terminal session and removes it from the list
    func closeSession(_ session: ConnectionSession) {
        let sessionId = session.id
        let title = session.title

        // Cancel shell task first to stop async work
        shellCancelHandlers[sessionId]?()
        shellCancelHandlers.removeValue(forKey: sessionId)

        // Remove from UI immediately
        sessions.removeAll { $0.id == sessionId }

        // Select another session if this was selected
        if selectedSessionId == sessionId {
            selectedSessionId = sessions.last?.id
        }

        // Unregister terminal view
        unregisterTerminal(for: sessionId)

        // Disconnect SSH client in background
        Task.detached(priority: .high) { [weak self] in
            await self?.unregisterSSHClient(for: sessionId)
        }

        logger.info("Closed terminal session \(title)")
    }

    // MARK: - Disconnect All

    /// Fully disconnects all sessions for a server and clears connection state
    func disconnectAll() {
        let sessionsToClose = sessions
        for session in sessionsToClose {
            closeSession(session)
        }
        connectedServerId = nil
        logger.info("Disconnected all sessions")
    }

    // MARK: - Tab Navigation

    func selectSession(_ session: ConnectionSession) {
        selectedSessionId = session.id
    }

    func selectPreviousSession() {
        guard let currentId = selectedSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedSessionId = sessions[currentIndex - 1].id
    }

    func selectNextSession() {
        guard let currentId = selectedSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }),
              currentIndex < sessions.count - 1 else { return }
        selectedSessionId = sessions[currentIndex + 1].id
    }

    func selectSession(at index: Int) {
        guard index >= 0 && index < sessions.count else { return }
        selectedSessionId = sessions[index].id
    }

    // MARK: - Close Operations

    func closeOtherSessions(except session: ConnectionSession) {
        let toClose = sessions.filter { $0.id != session.id }
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToLeft(of session: ConnectionSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let toClose = Array(sessions[..<index])
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToRight(of session: ConnectionSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let toClose = Array(sessions[(index + 1)...])
        for s in toClose {
            closeSession(s)
        }
    }

    // MARK: - SSH Client Registration

    func registerSSHClient(_ client: SSHClient, for sessionId: UUID) {
        sshClients[sessionId] = client
    }

    func unregisterSSHClient(for sessionId: UUID) async {
        if let client = sshClients.removeValue(forKey: sessionId) {
            await client.disconnect()
        }
    }

    func sshClient(for session: ConnectionSession) -> SSHClient? {
        sshClients[session.id]
    }

    // MARK: - Terminal Registration

    func registerTerminal(_ terminal: GhosttyTerminalView, for sessionId: UUID) {
        terminalViews[sessionId] = terminal
    }

    func unregisterTerminal(for sessionId: UUID) {
        terminalViews.removeValue(forKey: sessionId)
    }

    // MARK: - Shell Cancel Handler Registration

    func registerShellCancelHandler(_ handler: @escaping () -> Void, for sessionId: UUID) {
        shellCancelHandlers[sessionId] = handler
    }

    func unregisterShellCancelHandler(for sessionId: UUID) {
        shellCancelHandlers.removeValue(forKey: sessionId)
    }

    func getTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        terminalViews[sessionId]
    }

    /// Send text to the terminal for a given session (used by voice input)
    func sendText(_ text: String, to sessionId: UUID) {
        guard let terminal = terminalViews[sessionId] else { return }
        terminal.sendText(text)
    }

    // MARK: - Reconnection

    func reconnect(session: ConnectionSession) async throws {
        guard let serverManager = ServerManager.shared as ServerManager?,
              let server = serverManager.servers.first(where: { $0.id == session.serverId }) else {
            throw SSHError.connectionFailed("Server not found")
        }

        // Update state
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].connectionState = .reconnecting(attempt: 1)
        }

        // Disconnect existing SSH client
        await unregisterSSHClient(for: session.id)

        // Reconnect by updating state (terminal view will reconnect)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].connectionState = .connected
        }
    }
}

// MARK: - Connection Reliability Manager

actor ConnectionReliabilityManager {
    private var reconnectAttempts = 0
    private let maxAttempts = 5
    private let baseDelay: TimeInterval = 1.0

    func handleDisconnect(session: ConnectionSession) async {
        guard session.autoReconnect else { return }

        while reconnectAttempts < maxAttempts {
            reconnectAttempts += 1
            let delay = baseDelay * pow(2, Double(reconnectAttempts - 1))

            try? await Task.sleep(for: .seconds(delay))

            do {
                try await ConnectionSessionManager.shared.reconnect(session: session)
                reconnectAttempts = 0
                return
            } catch {
                continue
            }
        }
    }

    func resetAttempts() {
        reconnectAttempts = 0
    }
}
