import Foundation
import Combine
import os.log
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

// MARK: - Connection Session Manager

@MainActor
final class ConnectionSessionManager: ObservableObject {
    static let shared = ConnectionSessionManager()

    @Published var sessions: [ConnectionSession] = [] {
        didSet {
            LiveActivityManager.shared.refresh(with: sessions)
        }
    }
    @Published var selectedSessionId: UUID?

    /// Servers we're currently connected to (persists even when all terminals closed)
    /// Cleared when user explicitly disconnects from a server
    @Published var connectedServerIds: Set<UUID> = []

    /// Per-server view state (stats/terminal) - persists when switching servers
    @Published var selectedViewByServer: [UUID: String] = [:]

    /// Per-server selected terminal tab - persists when switching servers
    @Published var selectedSessionByServer: [UUID: UUID] = [:]


    /// Legacy single server ID for backward compatibility
    var connectedServerId: UUID? {
        get { connectedServerIds.first }
        set {
            if let id = newValue {
                connectedServerIds.insert(id)
            } else {
                connectedServerIds.removeAll()
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ConnectionSession")

    /// SSH clients indexed by session ID for stats collection and command execution
    private var sshClients: [UUID: SSHClient] = [:]

    /// Terminal views indexed by session ID for voice input and other external interactions
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]

    /// Shell cancel handlers indexed by session ID - called before closing to cancel async tasks
    private var shellCancelHandlers: [UUID: () -> Void] = [:]

    // MARK: - LRU Terminal Cache

    /// Maximum number of terminal surfaces to keep in memory
    /// Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
    private let maxTerminals = 20

    /// LRU access order - most recently accessed at the end
    private var terminalAccessOrder: [UUID] = []

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
        // Check if server is locked due to downgrade
        if ServerManager.shared.isServerLocked(server) {
            throw VivyTermError.serverLocked(server.name)
        }

        guard canOpenNewTab else {
            throw VivyTermError.proRequired(String(localized: "Upgrade to Pro for multiple connections"))
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
        let wasSelected = selectedSessionId == sessionId
        var replacementSessionId: UUID?

        if wasSelected {
            let serverSessions = sessions.filter { $0.serverId == session.serverId }
            if let index = serverSessions.firstIndex(where: { $0.id == sessionId }) {
                if index + 1 < serverSessions.count {
                    replacementSessionId = serverSessions[index + 1].id
                } else if index > 0 {
                    replacementSessionId = serverSessions[index - 1].id
                }
            }

            if replacementSessionId == nil,
               let fallback = sessions.first(where: { $0.id != sessionId }) {
                replacementSessionId = fallback.id
            }
        }

        // Cancel shell task first to stop async work
        shellCancelHandlers[sessionId]?()
        shellCancelHandlers.removeValue(forKey: sessionId)

        // Remove from UI immediately
        sessions.removeAll { $0.id == sessionId }

        // Select another session if this was selected (prefer same server)
        if wasSelected {
            selectedSessionId = replacementSessionId
        }

        // Unregister terminal view (defer cleanup if still attached to a window)
        if let terminal = terminalViews[sessionId], terminal.window != nil {
            terminal.pauseRendering()
            if !wasSelected {
                _ = terminal.resignFirstResponder()
            }
        } else {
            unregisterTerminal(for: sessionId)
        }

        if let replacementSessionId,
           let replacementTerminal = terminalViews[replacementSessionId],
           replacementTerminal.window != nil {
            DispatchQueue.main.async {
                _ = replacementTerminal.becomeFirstResponder()
            }
        }

        // Disconnect SSH client in background
        Task.detached(priority: .high) { [weak self] in
            await self?.unregisterSSHClient(for: sessionId)
        }

        if let selectedId = replacementSessionId ?? selectedSessionId,
           let selectedSession = sessions.first(where: { $0.id == selectedId }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.redrawSessionAfterClose(selectedSession)
            }
        }

        logger.info("Closed terminal session \(title)")
    }

    private func redrawSessionAfterClose(_ session: ConnectionSession) {
        guard let terminal = terminalViews[session.id] else { return }
        terminal.resumeRendering()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak terminal] in
            guard let terminal = terminal else { return }
            terminal.forceRefresh()

            if let size = terminal.terminalSize(),
               let client = self?.sshClient(for: session) {
                Task {
                    try? await client.resize(cols: Int(size.columns), rows: Int(size.rows))
                }
            }

            // Nudge the shell to redraw the prompt after layout changes without adding a new line.
            #if os(iOS)
            terminal.sendText("\u{0C}")
            #endif
        }
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

    /// Disconnect all sessions for a specific server
    func disconnectServer(_ serverId: UUID) {
        let sessionsToClose = sessions.filter { $0.serverId == serverId }
        for session in sessionsToClose {
            closeSession(session)
        }
        connectedServerIds.remove(serverId)
        if connectedServerIds.isEmpty {
            connectedServerId = nil
        }
        logger.info("Disconnected all sessions for server \(serverId)")
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

    // MARK: - Terminal Registration (with LRU caching)

    func registerTerminal(_ terminal: GhosttyTerminalView, for sessionId: UUID) {
        // Evict oldest terminals if we're at capacity
        evictOldTerminalsIfNeeded()

        terminalViews[sessionId] = terminal
        touchTerminal(sessionId)

        logger.debug("Registered terminal for session, total: \(self.terminalViews.count)/\(self.maxTerminals)")
    }

    func unregisterTerminal(for sessionId: UUID) {
        if let terminal = terminalViews.removeValue(forKey: sessionId) {
            // Ensure cleanup is called to free Ghostty surface
            terminal.cleanup()
        }
        terminalAccessOrder.removeAll { $0 == sessionId }
        logger.debug("Unregistered terminal, remaining: \(self.terminalViews.count)")
    }

    /// Update access order for LRU tracking
    private func touchTerminal(_ sessionId: UUID) {
        terminalAccessOrder.removeAll { $0 == sessionId }
        terminalAccessOrder.append(sessionId)
    }

    /// Evict least recently used terminals if over capacity
    private func evictOldTerminalsIfNeeded() {
        while terminalViews.count >= maxTerminals, let oldestId = terminalAccessOrder.first {
            // Don't evict the currently selected session
            if oldestId == selectedSessionId {
                terminalAccessOrder.removeFirst()
                terminalAccessOrder.append(oldestId)
                continue
            }

            logger.info("Evicting oldest terminal to free memory (count: \(self.terminalViews.count))")

            // Remove from access order
            terminalAccessOrder.removeFirst()

            // Cleanup and remove terminal
            if let terminal = terminalViews.removeValue(forKey: oldestId) {
                terminal.cleanup()
            }

            // Also cleanup associated SSH client
            if let client = sshClients.removeValue(forKey: oldestId) {
                Task.detached {
                    await client.disconnect()
                }
            }

            // Call shell cancel handler
            shellCancelHandlers[oldestId]?()
            shellCancelHandlers.removeValue(forKey: oldestId)
        }
    }

    // MARK: - Shell Cancel Handler Registration

    func registerShellCancelHandler(_ handler: @escaping () -> Void, for sessionId: UUID) {
        shellCancelHandlers[sessionId] = handler
    }

    func unregisterShellCancelHandler(for sessionId: UUID) {
        shellCancelHandlers.removeValue(forKey: sessionId)
    }

    func getTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        if let terminal = terminalViews[sessionId] {
            touchTerminal(sessionId)
            return terminal
        }
        return nil
    }

    /// Send text to the terminal for a given session (used by voice input)
    func sendText(_ text: String, to sessionId: UUID) {
        guard let terminal = terminalViews[sessionId] else { return }
        terminal.sendText(text)
    }

    // MARK: - Reconnection

    func reconnect(session: ConnectionSession) async throws {
        guard let serverManager = ServerManager.shared as ServerManager?,
              serverManager.servers.contains(where: { $0.id == session.serverId }) else {
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
