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

struct SSHShellRegistry {
    struct Registration {
        let serverId: UUID
        let client: SSHClient
        let shellId: UUID
        let transport: ShellTransport
        let fallbackReason: MoshFallbackReason?
    }

    struct StartContext {
        let startedAt: Date
        let client: SSHClient
        let serverId: UUID
    }

    struct RegisterResult {
        let accepted: Bool
        let staleIncomingShell: (client: SSHClient, shellId: UUID)?
        let replacedShell: (client: SSHClient, shellId: UUID)?
    }

    struct StartResult {
        let started: Bool
        let staleContext: StartContext?
    }

    struct InFlightResult {
        let inFlight: Bool
        let staleContext: StartContext?
    }

    private(set) var registrations: [UUID: Registration] = [:]
    private(set) var startsInFlight: [UUID: StartContext] = [:]
    private let staleThreshold: TimeInterval

    init(staleThreshold: TimeInterval) {
        self.staleThreshold = staleThreshold
    }

    mutating func register(
        client: SSHClient,
        shellId: UUID,
        for entityId: UUID,
        serverId: UUID,
        transport: ShellTransport,
        fallbackReason: MoshFallbackReason?
    ) -> RegisterResult {
        if let context = startsInFlight[entityId],
           ObjectIdentifier(context.client) != ObjectIdentifier(client) {
            return RegisterResult(
                accepted: false,
                staleIncomingShell: (client: client, shellId: shellId),
                replacedShell: nil
            )
        }

        startsInFlight.removeValue(forKey: entityId)
        let newRegistration = Registration(
            serverId: serverId,
            client: client,
            shellId: shellId,
            transport: transport,
            fallbackReason: fallbackReason
        )
        let replaced = registrations.updateValue(newRegistration, forKey: entityId)
        return RegisterResult(
            accepted: true,
            staleIncomingShell: nil,
            replacedShell: replaced.map { (client: $0.client, shellId: $0.shellId) }
        )
    }

    mutating func unregister(for entityId: UUID) -> (registration: Registration?, pendingStart: StartContext?) {
        let pendingStart = startsInFlight.removeValue(forKey: entityId)
        let registration = registrations.removeValue(forKey: entityId)
        return (registration, pendingStart)
    }

    mutating func tryBeginStart(
        for entityId: UUID,
        serverId: UUID,
        client: SSHClient,
        now: Date = Date()
    ) -> StartResult {
        if registrations[entityId] != nil {
            return StartResult(started: false, staleContext: nil)
        }

        if let context = startsInFlight[entityId] {
            if now.timeIntervalSince(context.startedAt) < staleThreshold {
                return StartResult(started: false, staleContext: nil)
            }
            startsInFlight.removeValue(forKey: entityId)
            startsInFlight[entityId] = StartContext(
                startedAt: now,
                client: client,
                serverId: serverId
            )
            return StartResult(started: true, staleContext: context)
        }

        startsInFlight[entityId] = StartContext(
            startedAt: now,
            client: client,
            serverId: serverId
        )
        return StartResult(started: true, staleContext: nil)
    }

    mutating func finishStart(for entityId: UUID, client: SSHClient) {
        guard let context = startsInFlight[entityId] else { return }
        guard ObjectIdentifier(context.client) == ObjectIdentifier(client) else { return }
        startsInFlight.removeValue(forKey: entityId)
    }

    mutating func isStartInFlight(for entityId: UUID, now: Date = Date()) -> InFlightResult {
        guard let context = startsInFlight[entityId] else {
            return InFlightResult(inFlight: false, staleContext: nil)
        }

        if now.timeIntervalSince(context.startedAt) >= staleThreshold {
            startsInFlight.removeValue(forKey: entityId)
            return InFlightResult(inFlight: false, staleContext: context)
        }

        return InFlightResult(inFlight: true, staleContext: nil)
    }

    func registration(for entityId: UUID) -> Registration? {
        registrations[entityId]
    }

    func shellId(for entityId: UUID) -> UUID? {
        registrations[entityId]?.shellId
    }

    func client(for entityId: UUID) -> SSHClient? {
        registrations[entityId]?.client
    }

    func hasOtherRegistrations(using client: SSHClient, excluding entityId: UUID) -> Bool {
        let identifier = ObjectIdentifier(client)
        return registrations.contains { registration in
            registration.key != entityId && ObjectIdentifier(registration.value.client) == identifier
        }
    }

    func hasClientReferences(_ client: SSHClient) -> Bool {
        hasActiveRegistration(using: client) || hasPendingStart(using: client)
    }

    func hasActiveRegistration(using client: SSHClient) -> Bool {
        let identifier = ObjectIdentifier(client)
        return registrations.values.contains { ObjectIdentifier($0.client) == identifier }
    }

    func hasPendingStart(using client: SSHClient) -> Bool {
        let identifier = ObjectIdentifier(client)
        return startsInFlight.values.contains { ObjectIdentifier($0.client) == identifier }
    }

    func firstRegisteredClient(for serverId: UUID) -> SSHClient? {
        registrations.values.first(where: { $0.serverId == serverId })?.client
    }

    func firstPendingClient(for serverId: UUID) -> SSHClient? {
        startsInFlight.values.first(where: { $0.serverId == serverId })?.client
    }

    mutating func removeAll() {
        registrations.removeAll()
        startsInFlight.removeAll()
    }
}

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

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver = TmuxAttachResolver()

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
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)

    /// Terminal views indexed by session ID for voice input and other external interactions
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]

    /// Shell cancel handlers indexed by session ID - called before closing to cancel async tasks
    private var shellCancelHandlers: [UUID: () -> Void] = [:]
    /// Shell suspend handlers indexed by session ID - cancel in-flight connects without destroying terminals
    private var shellSuspendHandlers: [UUID: () -> Void] = [:]
    /// Server IDs with an in-flight open request, used to collapse repeated clicks.
    private var sessionOpensInFlight: Set<UUID> = []

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
            throw VVTermError.serverLocked(server.name)
        }

        guard await AppLockManager.shared.ensureServerUnlocked(server) else {
            throw VVTermError.authenticationFailed
        }

        if sessionOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A connection is already opening for this server.")
            )
        }
        sessionOpensInFlight.insert(server.id)
        defer { sessionOpensInFlight.remove(server.id) }

        // Check if already have a session for this server (unless forcing new)
        if !forceNew, let existingSession = sessions.first(where: { $0.serverId == server.id }) {
            selectedSessionId = existingSession.id
            return existingSession
        }

        guard canOpenNewTab else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for multiple connections"))
        }

        let preferredSessionId = selectedSessionByServer[server.id] ?? selectedSessionId
        let fallbackSessionId = sessions.first(where: { $0.serverId == server.id })?.id
        let sourceSessionId = preferredSessionId ?? fallbackSessionId
        var sourceWorkingDirectory = sessions.first(where: { $0.id == sourceSessionId })?.workingDirectory
            ?? sessions.first(where: { $0.serverId == server.id })?.workingDirectory
        if tmuxResolver.isTmuxEnabled(for: server.id),
           let sourceSessionId,
           let sourceSession = sessions.first(where: { $0.id == sourceSessionId }),
           let client = sshClient(for: sourceSession),
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: sourceSessionId),
               using: client
           ) {
            sourceWorkingDirectory = path
            if let index = sessions.firstIndex(where: { $0.id == sourceSessionId }) {
                sessions[index].workingDirectory = path
            }
        }

        // Create new session - actual SSH connection happens in SSHTerminalWrapper
        let session = ConnectionSession(
            serverId: server.id,
            title: server.name,
            connectionState: .connecting,  // Will connect when terminal view appears
            tmuxStatus: tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off,
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
        case .connecting, .reconnecting:
            sessions[index].activeTransport = .ssh
            sessions[index].moshFallbackReason = nil
        case .idle:
            break
        }
    }

    func sessionState(for sessionId: UUID) -> ConnectionState? {
        sessions.first(where: { $0.id == sessionId })?.connectionState
    }

    func hasOtherActiveSessions(for serverId: UUID, excluding sessionId: UUID) -> Bool {
        sessions.contains {
            $0.serverId == serverId
                && $0.id != sessionId
                && $0.connectionState.isConnected
        }
    }

    /// Returns true when the same SSH client instance is registered to another live session.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding sessionId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: sessionId)
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
        tmuxResolver.clearRuntimeState(for: sessionId, setPrompt: setTmuxAttachPrompt)

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

    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for sessionId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) {
        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: sessionId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration for session \(sessionId.uuidString, privacy: .public)")
            Task.detached(priority: .utility) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return
        }

        if let replaced = registerResult.replacedShell {
            Task.detached { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].activeTransport = transport
            sessions[index].moshFallbackReason = fallbackReason
        }

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
            }
        }
    }

    func unregisterSSHClient(for sessionId: UUID) async {
        let unregisterResult = shellRegistry.unregister(for: sessionId)

        guard let registration = unregisterResult.registration else {
            if let pendingStart = unregisterResult.pendingStart {
                if !shellRegistry.hasClientReferences(pendingStart.client) {
                    await pendingStart.client.disconnect()
                }
            }
            return
        }

        await registration.client.closeShell(registration.shellId)

        if !shellRegistry.hasClientReferences(registration.client) {
            await registration.client.disconnect()
        }

        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].activeTransport = .ssh
            sessions[index].moshFallbackReason = nil
        }
    }

    func sshClient(for session: ConnectionSession) -> SSHClient? {
        shellRegistry.client(for: session.id)
    }

    func shellId(for session: ConnectionSession) -> UUID? {
        shellRegistry.shellId(for: session.id)
    }

    func shellId(for sessionId: UUID) -> UUID? {
        shellRegistry.shellId(for: sessionId)
    }

    /// Returns true only for the first caller while no live shell exists for the session.
    func tryBeginShellStart(for sessionId: UUID, client: SSHClient) -> Bool {
        guard let serverId = sessions.first(where: { $0.id == sessionId })?.serverId else {
            return false
        }

        let startResult = shellRegistry.tryBeginStart(
            for: sessionId,
            serverId: serverId,
            client: client
        )

        if let context = startResult.staleContext {
            logger.warning("Recovered stale session shell-start lock for \(sessionId.uuidString, privacy: .public)")
            if !shellRegistry.hasClientReferences(context.client) {
                Task.detached(priority: .utility) { [client = context.client] in
                    await client.disconnect()
                }
            }
        }
        return startResult.started
    }

    func finishShellStart(for sessionId: UUID, client: SSHClient) {
        shellRegistry.finishStart(for: sessionId, client: client)
    }

    func isShellStartInFlight(for sessionId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: sessionId)
        if let context = result.staleContext {
            logger.warning("Cleared stale session shell-start in-flight flag for \(sessionId.uuidString, privacy: .public)")
            if !shellRegistry.hasClientReferences(context.client) {
                Task.detached(priority: .utility) { [client = context.client] in
                    await client.disconnect()
                }
            }
        }
        return result.inFlight
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let selectedId = selectedSessionId,
           let selectedSession = sessions.first(where: { $0.id == selectedId && $0.serverId == serverId }),
           let client = shellRegistry.client(for: selectedSession.id) {
            return client
        }

        if let anySession = sessions.first(where: { $0.serverId == serverId }),
           let client = shellRegistry.client(for: anySession.id) {
            return client
        }

        if let client = shellRegistry.firstRegisteredClient(for: serverId) {
            return client
        }

        if allowPendingStart, let client = shellRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func activeTransport(for sessionId: UUID) -> ShellTransport {
        sessions.first(where: { $0.id == sessionId })?.activeTransport ?? .ssh
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if selectedTransport(for: serverId) == .mosh {
            return nil
        }
        return sshClient(for: serverId)
    }

    private func selectedTransport(for serverId: UUID) -> ShellTransport {
        if let selectedSessionId = selectedSessionByServer[serverId],
           let session = sessions.first(where: { $0.id == selectedSessionId }) {
            return session.activeTransport
        }

        if let selectedSessionId,
           let session = sessions.first(where: { $0.id == selectedSessionId && $0.serverId == serverId }) {
            return session.activeTransport
        }

        if let connected = sessions.first(where: { $0.serverId == serverId && $0.connectionState.isConnected }) {
            return connected.activeTransport
        }

        return sessions.first(where: { $0.serverId == serverId })?.activeTransport ?? .ssh
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

        if let current = sessions.first(where: { $0.id == session.id }),
           current.connectionState.isConnecting {
            return
        }

        // Update state
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].connectionState = .reconnecting(attempt: 1)
        }

        // Cancel in-flight shell work but keep the terminal surface for reuse
        shellSuspendHandlers[session.id]?()

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
                if !tmuxResolver.isTmuxEnabled(for: serverId) {
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
    private func resolveTmuxWorkingDirectory(for sessionId: UUID, using client: SSHClient) async -> String {
        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxResolver.sessionName(for: sessionId),
            using: client
        ) {
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].workingDirectory = path
            }
            return path
        }

        if let candidate = sessions.first(where: { $0.id == sessionId })?.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
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

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for session in sessions where session.serverId == serverId {
            let ownership = tmuxResolver.sessionOwnership[session.id] ?? .managed
            guard ownership == .managed else { continue }
            names.insert(tmuxResolver.sessionName(for: session.id))
        }
        return names
    }

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    func resolveTmuxAttachPrompt(sessionId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: sessionId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(sessionId: UUID) {
        tmuxResolver.cancelPrompt(entityId: sessionId, setPrompt: setTmuxAttachPrompt)
    }

    private func currentTmuxStatus(for sessionId: UUID) -> TmuxStatus {
        selectedSessionId == sessionId ? .foreground : .background
    }

    private func handleTmuxLifecycle(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.tmuxResolver.clearAttachmentState(for: sessionId)
                self.updateTmuxStatus(sessionId, status: .off)
            }
            return
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            await MainActor.run {
                self.tmuxResolver.clearAttachmentState(for: sessionId)
                self.updateTmuxStatus(sessionId, status: .missing)
            }
            return
        }

        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: managedTmuxSessionNames(for: serverId),
            using: client
        )
        tmuxCleanupServers = cleanupSet

        let status = await MainActor.run {
            self.currentTmuxStatus(for: sessionId)
        }
        await MainActor.run {
            self.updateTmuxStatus(sessionId, status: status)
        }

        await RemoteTmuxManager.shared.prepareConfig(using: client)

        let command: String
        if let pending = tmuxResolver.pendingPostShellCommands.removeValue(forKey: sessionId) {
            command = pending
        } else {
            let selection: TmuxAttachSelection
            if tmuxResolver.sessionOwnership[sessionId] == .external {
                selection = .attachExisting(sessionName: tmuxResolver.sessionName(for: sessionId))
            } else {
                selection = .createManaged
                tmuxResolver.sessionNames[sessionId] = tmuxResolver.managedSessionName(for: sessionId)
                tmuxResolver.sessionOwnership[sessionId] = .managed
            }
            let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
            guard let rebuilt = tmuxResolver.buildAttachCommand(for: sessionId, selection: selection, workingDirectory: workingDirectory) else {
                return
            }
            command = rebuilt
        }

        await RemoteTmuxManager.shared.sendScript(command, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for sessionId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        tmuxResolver.pendingPostShellCommands.removeValue(forKey: sessionId)

        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            tmuxResolver.clearAttachmentState(for: sessionId)
            updateTmuxStatus(sessionId, status: .off)
            return (nil, true)
        }

        let tmuxAvailable = await RemoteTmuxManager.shared.isTmuxAvailable(using: client)
        guard tmuxAvailable else {
            tmuxResolver.clearAttachmentState(for: sessionId)
            updateTmuxStatus(sessionId, status: .missing)
            return (nil, true)
        }

        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: managedTmuxSessionNames(for: serverId),
            using: client
        )
        tmuxCleanupServers = cleanupSet

        let selection = await tmuxResolver.resolveSelection(
            for: sessionId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: sessionId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updateTmuxStatus(sessionId, status: .off)
            return (nil, true)
        }

        updateTmuxStatus(sessionId, status: currentTmuxStatus(for: sessionId))
        await RemoteTmuxManager.shared.prepareConfig(using: client)

        let connectionMode = ServerManager.shared.servers
            .first(where: { $0.id == serverId })?
            .connectionMode ?? .standard

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)

        switch selection {
        case .skipTmux:
            return (nil, true)
        case .createManaged:
            if connectionMode == .mosh {
                tmuxResolver.pendingPostShellCommands[sessionId] = RemoteTmuxManager.shared.attachCommand(
                    sessionName: tmuxResolver.sessionName(for: sessionId),
                    workingDirectory: workingDirectory
                )
                return (nil, false)
            }
            return (
                RemoteTmuxManager.shared.attachExecCommand(
                    sessionName: tmuxResolver.sessionName(for: sessionId),
                    workingDirectory: workingDirectory
                ),
                true
            )
        case .attachExisting(let sessionName):
            if connectionMode == .mosh {
                tmuxResolver.pendingPostShellCommands[sessionId] = RemoteTmuxManager.shared.attachExistingCommand(sessionName: sessionName)
                return (nil, false)
            }
            return (
                RemoteTmuxManager.shared.attachExistingExecCommand(sessionName: sessionName),
                true
            )
        }
    }

    func startTmuxInstall(for sessionId: UUID) async {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updateTmuxStatus(sessionId, status: .installing)

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: registration.client)
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: sessionName,
            workingDirectory: workingDirectory
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client)
                if available {
                    await MainActor.run {
                        self.tmuxResolver.sessionNames[sessionId] = sessionName
                        self.tmuxResolver.sessionOwnership[sessionId] = .managed
                        self.updateTmuxStatus(sessionId, status: self.currentTmuxStatus(for: sessionId))
                    }
                    return
                }
            }
            await MainActor.run {
                self.updateTmuxStatus(sessionId, status: .missing)
            }
        }
    }

    func installMoshServer(for sessionId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: sessionId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    func killTmuxIfNeeded(for sessionId: UUID) {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let ownership = tmuxResolver.sessionOwnership[sessionId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        Task.detached { [client = registration.client, sessionName] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client)
        }
    }

    func disableTmux(for serverId: UUID) {
        for index in sessions.indices where sessions[index].serverId == serverId {
            sessions[index].tmuxStatus = .off
            tmuxResolver.clearRuntimeState(for: sessions[index].id, setPrompt: setTmuxAttachPrompt)
        }
    }
}

#if DEBUG
extension ConnectionSessionManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil

        let allSessionIds = Set(sessions.map(\.id))
            .union(shellRegistry.startsInFlight.keys)
        for sessionId in allSessionIds {
            tmuxResolver.clearRuntimeState(for: sessionId, setPrompt: setTmuxAttachPrompt)
        }

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellRegistry.registrations.values {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for context in shellRegistry.startsInFlight.values {
            uniqueClients[ObjectIdentifier(context.client)] = context.client
        }

        let terminals = Array(terminalViews.values)
        isRestoring = true
        sessions = []
        selectedSessionId = nil
        connectedServerIds = []
        selectedViewByServer = [:]
        selectedSessionByServer = [:]
        tmuxAttachPrompt = nil
        shellRegistry.removeAll()
        shellCancelHandlers.removeAll()
        shellSuspendHandlers.removeAll()
        sessionOpensInFlight.removeAll()
        tmuxCleanupServers.removeAll()
        terminalViews.removeAll()
        terminalAccessOrder.removeAll()
        isRestoring = false

        UserDefaults.standard.removeObject(forKey: persistenceKey)
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }
}
#endif

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
