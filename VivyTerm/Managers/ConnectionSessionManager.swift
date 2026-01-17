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
            schedulePersist()
        }
    }
    @Published var selectedSessionId: UUID? {
        didSet {
            schedulePersist()
            updateTmuxSelectionStatuses()
        }
    }

    /// Servers we're currently connected to (persists even when all terminals closed)
    /// Cleared when user explicitly disconnects from a server
    @Published var connectedServerIds: Set<UUID> = []

    /// Per-server view state (stats/terminal) - persists when switching servers
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    /// Per-server selected terminal tab - persists when switching servers
    @Published var selectedSessionByServer: [UUID: UUID] = [:] {
        didSet { schedulePersist() }
    }


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

    private struct SSHShellRegistration {
        let serverId: UUID
        let client: SSHClient
        let shellId: UUID
    }

    /// Shell handles indexed by session ID
    private var sshShells: [UUID: SSHShellRegistration] = [:]

    /// Shared SSH clients per server
    private var sharedSSHClients: [UUID: SSHClient] = [:]

    /// Shell counts per server for shared client lifecycle
    private var serverShellCounts: [UUID: Int] = [:]

    /// Terminal views indexed by session ID for voice input and other external interactions
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]

    /// Shell cancel handlers indexed by session ID - called before closing to cancel async tasks
    private var shellCancelHandlers: [UUID: () -> Void] = [:]
    /// Shell suspend handlers indexed by session ID - cancel in-flight connects without destroying terminals
    private var shellSuspendHandlers: [UUID: () -> Void] = [:]

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    // MARK: - LRU Terminal Cache

    /// Maximum number of terminal surfaces to keep in memory
    /// Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
    private let maxTerminals = 20

    /// LRU access order - most recently accessed at the end
    private var terminalAccessOrder: [UUID] = []

    private let persistenceKey = "connectionSessionsSnapshot.v1"
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    // MARK: - Session Management

    var selectedSession: ConnectionSession? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeSessions: [ConnectionSession] {
        sessions.filter { $0.connectionState.isConnected || $0.connectionState.isConnecting }
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

        // Check if already have a session for this server (unless forcing new)
        if !forceNew, let existingSession = sessions.first(where: { $0.serverId == server.id }) {
            selectedSessionId = existingSession.id
            return existingSession
        }

        guard canOpenNewTab else {
            throw VivyTermError.proRequired(String(localized: "Upgrade to Pro for multiple connections"))
        }

        let preferredSessionId = selectedSessionByServer[server.id] ?? selectedSessionId
        var sourceWorkingDirectory = sessions.first(where: { $0.id == preferredSessionId })?.workingDirectory
            ?? sessions.first(where: { $0.serverId == server.id })?.workingDirectory
        if sourceWorkingDirectory == nil,
           isTmuxEnabled(for: server.id),
           let sourceSessionId = preferredSessionId,
           let sourceSession = sessions.first(where: { $0.id == sourceSessionId }),
           let client = sshClient(for: sourceSession),
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxSessionName(for: sourceSessionId),
               using: client
           ) {
            sourceWorkingDirectory = path
        }

        // Create new session - actual SSH connection happens in SSHTerminalWrapper
        let session = ConnectionSession(
            serverId: server.id,
            title: server.name,
            connectionState: .connecting,  // Will connect when terminal view appears
            tmuxStatus: isTmuxEnabled(for: server.id) ? .unknown : .off,
            workingDirectory: sourceWorkingDirectory
        )

        sessions.append(session)
        selectedSessionId = session.id
        connectedServerId = server.id

        // Update server's last connected after the navigation animation completes
        Task { [server] in
            try? await Task.sleep(for: .milliseconds(350))
            await ServerManager.shared.updateLastConnected(for: server)
        }

        logger.info("Created session for \(server.name)")
        return session
    }

    // MARK: - Connection State Updates

    func updateSessionState(_ sessionId: UUID, to state: ConnectionState) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        sessions[index].connectionState = state
        let serverId = sessions[index].serverId

        switch state {
        case .connected:
            connectedServerIds.insert(serverId)
        case .disconnected, .failed:
            if sessions[index].tmuxStatus == .foreground {
                sessions[index].tmuxStatus = .background
            }
            let hasOtherConnections = sessions.contains {
                $0.serverId == serverId && $0.connectionState.isConnected
            }
            if !hasOtherConnections {
                connectedServerIds.remove(serverId)
            }
        case .connecting, .reconnecting, .idle:
            break
        }
    }

    func sessionState(for sessionId: UUID) -> ConnectionState? {
        sessions.first(where: { $0.id == sessionId })?.connectionState
    }

    func updateTmuxStatus(_ sessionId: UUID, status: TmuxStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].tmuxStatus = status
    }

    func updateSessionWorkingDirectory(_ sessionId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].workingDirectory = normalized
    }

    // MARK: - Close Terminal

    /// Closes a terminal session and removes it from the list
    func closeSession(_ session: ConnectionSession) {
        let sessionId = session.id
        let title = session.title
        let wasSelected = selectedSessionId == sessionId
        var replacementSessionId: UUID?

        if session.tmuxStatus == .foreground || session.tmuxStatus == .background || session.tmuxStatus == .installing {
            killTmuxIfNeeded(for: sessionId)
        }

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
        shellSuspendHandlers.removeValue(forKey: sessionId)

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
               let client = self?.sshClient(for: session),
               let shellId = self?.shellId(for: session) {
                Task {
                    try? await client.resize(cols: Int(size.columns), rows: Int(size.rows), for: shellId)
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

    /// Disconnects all sessions without removing tabs (used when app backgrounds)
    func suspendAllForBackground() {
        let sessionsToSuspend = sessions
        for session in sessionsToSuspend {
            if session.connectionState.isConnected || session.connectionState.isConnecting {
                updateSessionState(session.id, to: .disconnected)
            }
            // Cancel any in-flight connects while preserving terminal state
            shellSuspendHandlers[session.id]?()
            Task.detached { [weak self] in
                await self?.unregisterSSHClient(for: session.id)
            }
        }
        logger.info("Suspended all sessions for background")
    }

    /// Handle shell exit without removing the session (keeps tab for reconnect)
    func handleShellExit(for sessionId: UUID) {
        updateSessionState(sessionId, to: .disconnected)
        Task.detached { [weak self] in
            await self?.unregisterSSHClient(for: sessionId)
        }
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

    func sharedSSHClient(for server: Server) -> SSHClient {
        if let client = sharedSSHClients[server.id] {
            return client
        }
        let client = SSHClient()
        sharedSSHClients[server.id] = client
        return client
    }

    func registerSSHClient(_ client: SSHClient, shellId: UUID, for sessionId: UUID, serverId: UUID) {
        if let existing = sshShells[sessionId] {
            Task.detached { [client = existing.client, shellId = existing.shellId] in
                await client.closeShell(shellId)
            }
            serverShellCounts[existing.serverId] = max((serverShellCounts[existing.serverId] ?? 1) - 1, 0)
        }

        sshShells[sessionId] = SSHShellRegistration(serverId: serverId, client: client, shellId: shellId)
        serverShellCounts[serverId, default: 0] += 1
        sharedSSHClients[serverId] = client

        Task { [weak self] in
            await self?.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
        }
    }

    func unregisterSSHClient(for sessionId: UUID) async {
        guard let registration = sshShells.removeValue(forKey: sessionId) else { return }

        await registration.client.closeShell(registration.shellId)

        let serverId = registration.serverId
        let newCount = max((serverShellCounts[serverId] ?? 1) - 1, 0)
        serverShellCounts[serverId] = newCount

        if newCount == 0, let client = sharedSSHClients.removeValue(forKey: serverId) {
            await client.disconnect()
        }
    }

    func sshClient(for session: ConnectionSession) -> SSHClient? {
        sshShells[session.id]?.client
    }

    func shellId(for session: ConnectionSession) -> UUID? {
        sshShells[session.id]?.shellId
    }

    func sshClient(for serverId: UUID) -> SSHClient? {
        if let client = sharedSSHClients[serverId] {
            return client
        }

        if let selectedId = selectedSessionId,
           let selectedSession = sessions.first(where: { $0.id == selectedId && $0.serverId == serverId }),
           let client = sshShells[selectedSession.id]?.client {
            return client
        }

        if let anySession = sessions.first(where: { $0.serverId == serverId }),
           let client = sshShells[anySession.id]?.client {
            return client
        }

        return nil
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

            // Also cleanup associated SSH shell
            Task.detached { [weak self] in
                await self?.unregisterSSHClient(for: oldestId)
            }

            // Call shell cancel handler
            shellCancelHandlers[oldestId]?()
            shellCancelHandlers.removeValue(forKey: oldestId)
            shellSuspendHandlers.removeValue(forKey: oldestId)
        }
    }

    // MARK: - Shell Cancel Handler Registration

    func registerShellCancelHandler(_ handler: @escaping () -> Void, for sessionId: UUID) {
        shellCancelHandlers[sessionId] = handler
    }

    func unregisterShellCancelHandler(for sessionId: UUID) {
        shellCancelHandlers.removeValue(forKey: sessionId)
    }

    func registerShellSuspendHandler(_ handler: @escaping () -> Void, for sessionId: UUID) {
        shellSuspendHandlers[sessionId] = handler
    }

    func unregisterShellSuspendHandler(for sessionId: UUID) {
        shellSuspendHandlers.removeValue(forKey: sessionId)
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
    }

}

// MARK: - Persistence

extension ConnectionSessionManager {
    private func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self?.persistSnapshot()
            }
        }
    }

    private func persistSnapshot() {
        let sessionsSnapshot = sessions.map { ConnectionSessionsSnapshot.SessionSnapshot(from: $0) }
        let serverSelections = Set(sessions.map(\.serverId)).map { serverId in
            ConnectionSessionsSnapshot.ServerSnapshot(
                serverId: serverId,
                selectedSessionId: selectedSessionByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }

        let snapshot = ConnectionSessionsSnapshot(
            sessions: sessionsSnapshot,
            selectedSessionId: selectedSessionId,
            serverSelections: serverSelections
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to persist session snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(ConnectionSessionsSnapshot.self, from: data)
            isRestoring = true

            var restoredSessions = snapshot.sessions.map { $0.toSession() }
            for index in restoredSessions.indices {
                let serverId = restoredSessions[index].serverId
                if !isTmuxEnabled(for: serverId) {
                    restoredSessions[index].tmuxStatus = .off
                }
            }
            sessions = restoredSessions
            selectedSessionId = snapshot.selectedSessionId
            selectedSessionByServer = Dictionary(
                uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                    guard let selected = snapshot.selectedSessionId else { return nil }
                    return (snapshot.serverId, selected)
                }
            )
            selectedViewByServer = Dictionary(
                uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                    guard let view = snapshot.selectedView else { return nil }
                    return (snapshot.serverId, view)
                }
            )
            connectedServerIds = Set(restoredSessions.map(\.serverId))
        } catch {
            logger.error("Failed to restore session snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}

private struct ConnectionSessionsSnapshot: Codable {
    struct SessionSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let lastActivity: Date
        let autoReconnect: Bool
        let parentSessionId: UUID?
        let workingDirectory: String?

        init(from session: ConnectionSession) {
            self.id = session.id
            self.serverId = session.serverId
            self.title = session.title
            self.createdAt = session.createdAt
            self.lastActivity = session.lastActivity
            self.autoReconnect = session.autoReconnect
            self.parentSessionId = session.parentSessionId
            self.workingDirectory = session.workingDirectory
        }

        func toSession() -> ConnectionSession {
            ConnectionSession(
                id: id,
                serverId: serverId,
                title: title,
                connectionState: .disconnected,
                createdAt: createdAt,
                lastActivity: lastActivity,
                terminalSurfaceId: nil,
                autoReconnect: autoReconnect,
                workingDirectory: workingDirectory,
                parentSessionId: parentSessionId
            )
        }
    }

    struct ServerSnapshot: Codable {
        let serverId: UUID
        let selectedSessionId: UUID?
        let selectedView: String?
    }

    let sessions: [SessionSnapshot]
    let selectedSessionId: UUID?
    let serverSelections: [ServerSnapshot]
}

// MARK: - tmux Integration

extension ConnectionSessionManager {
    private var tmuxEnabledDefault: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "terminalTmuxEnabledDefault") == nil {
            return true
        }
        return defaults.bool(forKey: "terminalTmuxEnabledDefault")
    }

    private func isTmuxEnabled(for serverId: UUID) -> Bool {
        if let server = ServerManager.shared.servers.first(where: { $0.id == serverId }) {
            if let override = server.tmuxEnabledOverride {
                return override
            }
        }
        return tmuxEnabledDefault
    }

    private func tmuxSessionName(for sessionId: UUID) -> String {
        "vvterm_\(DeviceIdentity.id)_\(sessionId.uuidString)"
    }

    private func resolveTmuxWorkingDirectory(for sessionId: UUID, using client: SSHClient) async -> String {
        if let candidate = sessions.first(where: { $0.id == sessionId })?.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxSessionName(for: sessionId),
            using: client
        ) {
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].workingDirectory = path
            }
            return path
        }

        return "~"
    }

    func workingDirectory(for sessionId: UUID) -> String? {
        sessions.first(where: { $0.id == sessionId })?.workingDirectory
    }

    func shouldApplyWorkingDirectory(for sessionId: UUID) -> Bool {
        guard let status = sessions.first(where: { $0.id == sessionId })?.tmuxStatus else { return false }
        return status == .off || status == .missing
    }

    private func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            return path.removingPercentEncoding ?? path
        }

        return trimmed
    }

    private func updateTmuxSelectionStatuses() {
        guard let selectedId = selectedSessionId else {
            for index in sessions.indices {
                if sessions[index].tmuxStatus == .foreground {
                    sessions[index].tmuxStatus = .background
                }
            }
            return
        }
        for index in sessions.indices {
            let status = sessions[index].tmuxStatus
            guard status == .foreground || status == .background else { continue }
            sessions[index].tmuxStatus = (sessions[index].id == selectedId) ? .foreground : .background
        }
    }

    private func handleTmuxLifecycle(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.updateTmuxStatus(sessionId, status: .off)
            }
            return
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            await MainActor.run {
                self.updateTmuxStatus(sessionId, status: .missing)
            }
            return
        }

        if !tmuxCleanupServers.contains(serverId) {
            tmuxCleanupServers.insert(serverId)
            let keepNames = Set(sessions.filter { $0.serverId == serverId }.map { tmuxSessionName(for: $0.id) })
            await RemoteTmuxManager.shared.cleanupLegacySessions(using: client)
            await RemoteTmuxManager.shared.cleanupDetachedSessions(
                deviceId: DeviceIdentity.id,
                keeping: keepNames,
                using: client
            )
        }

        let isSelected = await MainActor.run { self.selectedSessionId == sessionId }
        let status: TmuxStatus = isSelected ? .foreground : .background
        await MainActor.run {
            self.updateTmuxStatus(sessionId, status: status)
        }

        await RemoteTmuxManager.shared.prepareConfig(using: client)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        let command = RemoteTmuxManager.shared.attachCommand(
            sessionName: tmuxSessionName(for: sessionId),
            workingDirectory: workingDirectory
        )
        await RemoteTmuxManager.shared.sendScript(command, using: client, shellId: shellId)
    }

    func startTmuxInstall(for sessionId: UUID) async {
        guard let registration = sshShells[sessionId] else { return }
        let serverId = registration.serverId
        guard isTmuxEnabled(for: serverId) else { return }

        updateTmuxStatus(sessionId, status: .installing)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: registration.client)
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: tmuxSessionName(for: sessionId),
            workingDirectory: workingDirectory
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client)
                if available {
                    let isSelected = await MainActor.run { self.selectedSessionId == sessionId }
                    await MainActor.run {
                        self.updateTmuxStatus(sessionId, status: isSelected ? .foreground : .background)
                    }
                    return
                }
            }
            await MainActor.run {
                self.updateTmuxStatus(sessionId, status: .missing)
            }
        }
    }

    func killTmuxIfNeeded(for sessionId: UUID) {
        guard let registration = sshShells[sessionId] else { return }
        let sessionName = tmuxSessionName(for: sessionId)
        Task.detached { [client = registration.client, sessionName] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
        }
    }

    func disableTmux(for serverId: UUID) {
        for index in sessions.indices where sessions[index].serverId == serverId {
            sessions[index].tmuxStatus = .off
        }
    }
}

// MARK: - Connection Reliability Manager

actor ConnectionReliabilityManager {
    private var reconnectAttempts = 0
    private let maxAttempts = 3
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
