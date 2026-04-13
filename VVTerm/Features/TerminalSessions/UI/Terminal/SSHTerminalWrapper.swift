//
//  SSHTerminalWrapper.swift
//  VVTerm
//
//  SwiftUI wrapper for Ghostty terminal with SSH connections
//

import SwiftUI
import Foundation
import os.log

enum SSHConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        terminal: GhosttyTerminalView,
        logger: Logger,
        onAttempt: @escaping (_ attempt: Int) async -> Void,
        startupPlan: @escaping () async -> (command: String?, skipTmuxLifecycle: Bool),
        registerShell: @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Void,
        onBeforeShellStart: @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onShellStarted: @escaping (_ terminal: GhosttyTerminalView, _ shellId: UUID) async -> Void,
        shouldContinueStreaming: @escaping (_ data: Data, _ terminal: GhosttyTerminalView) async -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool,
        onProcessExit: @escaping () async -> Void,
        onFailure: @escaping (_ error: Error, _ terminal: GhosttyTerminalView) async -> Void
    ) async {
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            await onAttempt(attempt)

            do {
                logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                _ = try await sshClient.connect(to: server, credentials: credentials)
                guard !Task.isCancelled else { return }

                let size = terminal.terminalSize()
                let cols = Int(size?.columns ?? 80)
                let rows = Int(size?.rows ?? 24)

                await onBeforeShellStart(cols, rows)
                let startup = await startupPlan()
                let shell = try await sshClient.startShell(
                    cols: cols,
                    rows: rows,
                    startupCommand: startup.command
                )

                guard !Task.isCancelled else {
                    await sshClient.closeShell(shell.id)
                    return
                }

                await registerShell(shell, startup.skipTmuxLifecycle)
                await onShellStarted(terminal, shell.id)

                guard !Task.isCancelled else { return }
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    let shouldContinue = await shouldContinueStreaming(data, terminal)
                    if !shouldContinue { break }
                }

                guard !Task.isCancelled else { return }
                logger.info("SSH shell ended")
                await onProcessExit()
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
                logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    if shouldReset {
                        logger.warning("Resetting SSH client before retrying connection")
                        await sshClient.disconnect()
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }

        if let lastError {
            await onFailure(lastError, terminal)
        }
    }
}

// MARK: - SSH Terminal Coordinator Protocol

/// Protocol for shared SSH terminal coordinator functionality across platforms
protocol SSHTerminalCoordinator: AnyObject {
    var server: Server { get }
    var credentials: ServerCredentials { get }
    var sessionId: UUID { get }
    var onProcessExit: () -> Void { get }
    var terminalView: GhosttyTerminalView? { get set }
    var sshClient: SSHClient { get }
    var shellId: UUID? { get set }
    var shellTask: Task<Void, Never>? { get set }
    var logger: Logger { get }

    /// Platform-specific hook called after shell starts (before reading output)
    func onShellStarted(terminal: GhosttyTerminalView) async

    /// Platform-specific hook called before starting shell (after connect, after registering client)
    func onBeforeShellStart(cols: Int, rows: Int) async

    /// Fallback route when local shellId is temporarily unavailable.
    func fallbackRoute() -> (client: SSHClient, shellId: UUID)?
}

extension SSHTerminalCoordinator {
    func sendToSSH(_ data: Data) {
        if let shellId {
            // Preserve task ordering from the caller to avoid input reordering under high throughput.
            Task(priority: .userInitiated) { [sshClient, logger, shellId] in
                do {
                    try await sshClient.write(data, to: shellId)
                } catch {
                    logger.error("Failed to send to SSH: \(error.localizedDescription)")
                }
            }
            return
        }

        // Coordinator can be recreated while an existing shell is still registered.
        // Fall back to the manager registry so input keeps working after view reattachment.
        Task(priority: .userInitiated) { [logger] in
            let route = await MainActor.run {
                self.fallbackRoute()
            }

            guard let route else { return }
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }
    }

    func cancelShell() {
        shellTask?.cancel()
        shellTask = nil
        if let shellId {
            Task.detached(priority: .high) { [sshClient, shellId] in
                await sshClient.closeShell(shellId)
            }
        }
        self.shellId = nil

        // Cleanup terminal to break retain cycles and release resources
        if let terminal = terminalView {
            terminal.cleanup()
        }
        terminalView = nil
    }

    func suspendShell() {
        // Cancel in-flight SSH work but keep the terminal surface for reuse
        shellTask?.cancel()
        shellTask = nil
        self.shellId = nil
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        if shellTask != nil {
            logger.debug("Ignoring duplicate start request for session \(self.sessionId)")
            return
        }

        if let existingShellId = ConnectionSessionManager.shared.shellId(for: sessionId) {
            shellId = existingShellId
            deferSessionStateUpdate(.connected)
            logger.debug("Reusing existing shell for session \(self.sessionId)")
            return
        }

        if shellId != nil {
            deferSessionStateUpdate(.connected)
            logger.debug("Shell already active for session \(self.sessionId)")
            return
        }

        guard ConnectionSessionManager.shared.tryBeginShellStart(
            for: sessionId,
            client: sshClient
        ) else {
            if ConnectionSessionManager.shared.shellId(for: sessionId) != nil {
                deferSessionStateUpdate(.connected)
            }
            logger.debug("Shell start already in progress for session \(self.sessionId)")
            return
        }

        // Capture all values needed in the detached task before creating it
        // to avoid accessing main actor-isolated properties from detached context
        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let sessionId = self.sessionId
        let onProcessExit = self.onProcessExit
        let logger = self.logger

        shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal] in
            defer {
                Task { @MainActor [weak self] in
                    ConnectionSessionManager.shared.finishShellStart(for: sessionId, client: sshClient)
                    self?.shellTask = nil
                }
            }

            guard let self = self, let terminal = terminal else { return }
            await SSHConnectionRunner.run(
                server: server,
                credentials: credentials,
                sshClient: sshClient,
                terminal: terminal,
                logger: logger,
                onAttempt: { attempt in
                    await MainActor.run {
                        if attempt == 1 {
                            ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connecting)
                        } else {
                            ConnectionSessionManager.shared.updateSessionState(sessionId, to: .reconnecting(attempt: attempt))
                        }
                    }
                },
                startupPlan: {
                    await ConnectionSessionManager.shared.tmuxStartupPlan(
                        for: sessionId,
                        serverId: server.id,
                        client: sshClient
                    )
                },
                registerShell: { shell, skipTmuxLifecycle in
                    await MainActor.run {
                        ConnectionSessionManager.shared.registerSSHClient(
                            sshClient,
                            shellId: shell.id,
                            for: sessionId,
                            serverId: server.id,
                            transport: shell.transport,
                            fallbackReason: shell.fallbackReason,
                            skipTmuxLifecycle: skipTmuxLifecycle
                        )
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
                        self.shellId = shell.id
                    }
                },
                onBeforeShellStart: { cols, rows in
                    await self.onBeforeShellStart(cols: cols, rows: rows)
                },
                onShellStarted: { terminal, _ in
                    await self.onShellStarted(terminal: terminal)
                },
                shouldContinueStreaming: { data, terminal in
                    await MainActor.run {
                        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                        guard sessionExists else { return false }
                        terminal.feedData(data)
                        return true
                    }
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await MainActor.run {
                            ConnectionSessionManager.shared.hasOtherRegistrations(
                                using: sshClient,
                                excluding: sessionId
                            )
                        }
                        return !hasOtherRegistrations
                    case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed, .unknown:
                        return false
                    }
                },
                onProcessExit: {
                    await MainActor.run {
                        onProcessExit()
                    }
                },
                onFailure: { error, terminal in
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        await MainActor.run {
                            terminal.feedData(data)
                        }
                    }
                    await MainActor.run {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .failed(error.localizedDescription))
                    }
                }
            )
        }
    }

    private func deferSessionStateUpdate(_ state: ConnectionState) {
        DispatchQueue.main.async { [self] in
            ConnectionSessionManager.shared.updateSessionState(sessionId, to: state)
        }
    }

    // Default no-op implementations for hooks
    func onShellStarted(terminal: GhosttyTerminalView) async {}
    func onBeforeShellStart(cols: Int, rows: Int) async {}
    func fallbackRoute() -> (client: SSHClient, shellId: UUID)? {
        guard let session = ConnectionSessionManager.shared.sessions.first(where: { $0.id == sessionId }),
              let client = ConnectionSessionManager.shared.sshClient(for: session),
              let shellId = ConnectionSessionManager.shared.shellId(for: session) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }
}

#if os(macOS)
import AppKit

// MARK: - SSH Terminal Wrapper

struct SSHTerminalWrapper: NSViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        // Use a dedicated SSH client per tab/session to avoid channel contention
        // and startup races when many tabs are opened quickly.
        let client = SSHClient()
        return Coordinator(
            server: server,
            credentials: credentials,
            sessionId: session.id,
            onProcessExit: onProcessExit,
            sshClient: client,
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this session (reuse to save memory)
        // Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
        if let existingTerminal = ConnectionSessionManager.shared.getTerminal(for: session.id) {
            // Mark coordinator as reusing existing terminal - don't cleanup on deinit
            coordinator.isReusingTerminal = true
            coordinator.terminalView = existingTerminal

            // Update resize callback to use session manager's registered SSH client
            // (the old coordinator that created the connection is being deallocated)
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    if let client = ConnectionSessionManager.shared.sshClient(for: session),
                       let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                        try? await client.resize(cols: cols, rows: rows, for: shellId)
                    }
                }
            }
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            // Terminal is already ready - call onReady immediately
            // Use async to avoid calling during view construction
            DispatchQueue.main.async {
                onReady()
                let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
                let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if shellMissing && !shellStartInFlight {
                    if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                        existingTerminal.resetTerminalForReconnect()
                    }
                    coordinator.startSSHConnection(terminal: existingTerminal)
                }
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        // Using useCustomIO: true means the terminal won't spawn a subprocess
        // Instead, it will use callbacks for I/O (for SSH via libssh2)
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true  // Use callback backend for SSH
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            // Start SSH connection after terminal is ready
            if let terminalView = terminalView {
                coordinator?.startSSHConnection(terminal: terminalView)
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
            ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
        }

        // Store terminal reference in coordinator and register with session manager
        coordinator.terminalView = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

        // Register shell cancel handler so closeSession can cancel the shell task
        ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
            coordinator?.cancelShell()
        }, for: session.id)
        ConnectionSessionManager.shared.registerShellSuspendHandler({ [weak coordinator] in
            coordinator?.suspendShell()
        }, for: session.id)

        // Setup write callback to send keyboard input to SSH
        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.setupWriteCallback()

        // Setup resize callback to notify SSH of terminal size changes
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }

        // Wrap in scroll view
        let scrollView = TerminalScrollView(
            contentSize: NSSize(width: 800, height: 600),
            surfaceView: terminalView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            context.coordinator.cancelShell()
            return
        }

        if let scrollView = nsView as? TerminalScrollView {
            let terminalView = scrollView.surfaceView

            let wasActive = context.coordinator.wasActive
            context.coordinator.wasActive = isActive
            context.coordinator.focusRequestID &+= 1

            let currentWindowIdentity = nsView.window.map(ObjectIdentifier.init)
            let didAttachToWindow = currentWindowIdentity != nil && currentWindowIdentity != context.coordinator.lastWindowIdentity
            context.coordinator.lastWindowIdentity = currentWindowIdentity

            if isActive && (!wasActive || didAttachToWindow) {
                let focusRequestID = context.coordinator.focusRequestID
                DispatchQueue.main.async {
                    guard context.coordinator.focusRequestID == focusRequestID,
                          context.coordinator.wasActive,
                          let window = terminalView.window,
                          window.firstResponder !== terminalView else { return }
                    window.makeFirstResponder(terminalView)
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: SSHTerminalCoordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        private let richPasteRuntime: TerminalRichPasteRuntime
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// Last known terminal size to detect changes
        private var lastSize: (cols: Int, rows: Int) = (0, 0)

        /// If true, this coordinator is reusing an existing terminal and should NOT cleanup on deinit
        var isReusingTerminal = false
        var wasActive = false
        var lastWindowIdentity: ObjectIdentifier?
        var focusRequestID: UInt = 0

        init(
            server: Server,
            credentials: ServerCredentials,
            sessionId: UUID,
            onProcessExit: @escaping () -> Void,
            sshClient: SSHClient,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
            self.richPasteRuntime = .connectionSession(
                sessionId: sessionId,
                sshClient: sshClient,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        /// Handle terminal resize notification from GhosttyTerminalView
        func handleResize(cols: Int, rows: Int) {
            guard cols > 0 && rows > 0 else { return }
            guard cols != lastSize.cols || rows != lastSize.rows else { return }
            guard let shellId else { return }

            lastSize = (cols, rows)
            logger.info("Terminal resized to \(cols)x\(rows)")

            Task {
                do {
                    try await sshClient.resize(cols: cols, rows: rows, for: shellId)
                } catch {
                    logger.warning("Failed to resize PTY: \(error.localizedDescription)")
                }
            }
        }

        // MARK: - SSHTerminalCoordinator hooks

        func onBeforeShellStart(cols: Int, rows: Int) async {
            // Store initial size to avoid redundant resize on first update
            await MainActor.run {
                self.lastSize = (cols, rows)
            }
        }

        func onShellStarted(terminal: GhosttyTerminalView) async {
            await applyWorkingDirectoryIfNeeded()
        }

        private func applyWorkingDirectoryIfNeeded() async {
            guard ConnectionSessionManager.shared.shouldApplyWorkingDirectory(for: sessionId) else { return }
            guard let cwd = ConnectionSessionManager.shared.workingDirectory(for: sessionId) else { return }
            let environment = await sshClient.remoteEnvironment()
            guard environment.supportsWorkingDirectoryRestore else { return }
            guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(for: cwd, environment: environment).data(using: .utf8) else { return }
            if let shellId {
                try? await sshClient.write(payload, to: shellId)
            }
        }

        deinit {
            // Don't cleanup if we're just reusing an existing terminal (e.g., switching to split view)
            // isReusingTerminal is set when we find an existing terminal in makeNSView
            guard !isReusingTerminal else { return }

            // Check if terminal view is still alive (session manager holds strong reference)
            // If it is, the terminal is being reused by another view (e.g., split view)
            guard terminalView == nil else { return }

            cancelShell()
        }
    }
}

#else
// MARK: - iOS SSH Terminal Wrapper

import UIKit
import SwiftUI

/// SwiftUI wrapper that uses GeometryReader to get proper size (matches official Ghostty pattern)
struct SSHTerminalWrapper: View {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    var isActive: Bool = true
    var shouldPreserveKeyboardDuringReconnect: Bool = false
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            SSHTerminalRepresentable(
                session: session,
                server: server,
                credentials: credentials,
                richPasteUIModel: richPasteUIModel,
                size: geo.size,
                isActive: isActive,
                shouldPreserveKeyboardDuringReconnect: shouldPreserveKeyboardDuringReconnect,
                onProcessExit: onProcessExit,
                onReady: onReady,
                onVoiceTrigger: onVoiceTrigger
            )
        }
    }
}

/// The actual UIViewRepresentable that receives size from GeometryReader
private struct SSHTerminalRepresentable: UIViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let size: CGSize
    var isActive: Bool = true
    var shouldPreserveKeyboardDuringReconnect: Bool = false
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> Coordinator {
        // Use a dedicated SSH client per tab/session to avoid channel contention
        // and startup races when many tabs are opened quickly.
        let client = SSHClient()
        return Coordinator(
            server: server,
            credentials: credentials,
            sessionId: session.id,
            onProcessExit: onProcessExit,
            sshClient: client,
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this session (reuse to save memory)
        if let existingTerminal = ConnectionSessionManager.shared.peekTerminal(for: session.id) {
            ConnectionSessionManager.shared.markTerminalUsed(for: session.id)
            coordinator.terminalView = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preserveSession = true
            existingTerminal.onVoiceButtonTapped = onVoiceTrigger
            existingTerminal.onProcessExit = onProcessExit
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                DispatchQueue.main.async {
                    ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
                }
            }

            // Route through coordinator to preserve write ordering and transport behavior.
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                       let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                        try? await sshClient.resize(cols: cols, rows: rows, for: shellId)
                    }
                }
            }

            if existingTerminal.superview != nil {
                existingTerminal.removeFromSuperview()
            }
            if size.width > 0 && size.height > 0 {
                coordinator.lastReportedSize = size
                existingTerminal.frame = CGRect(origin: .zero, size: size)
                existingTerminal.sizeDidChange(size)
            }

            DispatchQueue.main.async {
                onReady()
                let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
                let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if shellMissing,
                   !shellStartInFlight,
                   UIApplication.shared.applicationState == .active,
                   !ConnectionSessionManager.shared.isSuspendingForBackground {
                    if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                        existingTerminal.resetTerminalForReconnect()
                    }
                    coordinator.startSSHConnection(terminal: existingTerminal)
                }
            }
            return existingTerminal
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            coordinator?.isTerminalReady = true
            DispatchQueue.main.async {
                onReady()
                if let terminalView = terminalView,
                   UIApplication.shared.applicationState == .active,
                   !ConnectionSessionManager.shared.isSuspendingForBackground {
                    coordinator?.startSSHConnection(terminal: terminalView)
                }
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
            DispatchQueue.main.async {
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }
        }

        coordinator.terminalView = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)
        ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
            coordinator?.cancelShell()
        }, for: session.id)
        ConnectionSessionManager.shared.registerShellSuspendHandler({ [weak coordinator] in
            coordinator?.suspendShell()
        }, for: session.id)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.setupWriteCallback()
        terminalView.onResize = { [session] cols, rows in
            guard cols > 0 && rows > 0 else { return }
            Task {
                if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                   let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                    try? await sshClient.resize(cols: cols, rows: rows, for: shellId)
                }
            }
        }

        coordinator.lastReportedSize = initialSize
        if size.width > 0 && size.height > 0 {
            terminalView.sizeDidChange(size)
        }
        if !isActive {
            terminalView.pauseRendering()
        }

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView else {
            return
        }

        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            // Session was closed externally, cleanup terminal
            context.coordinator.cancelShell()
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            return
        }

        let wasActive = context.coordinator.wasActive
        let shouldRenderTerminal = isActive && scenePhase == .active

        terminalView.onVoiceButtonTapped = onVoiceTrigger
        if size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            if shouldRenderTerminal && !wasActive {
                terminalView.resumeRendering()
                terminalView.forceRefresh()
            } else if !shouldRenderTerminal && wasActive {
                terminalView.pauseRendering()
            }
        }
        context.coordinator.wasActive = shouldRenderTerminal

        let autoReconnectEnabled = (UserDefaults.standard.object(forKey: "sshAutoReconnect") as? Bool) ?? true
        let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
        let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
        let shouldRestoreKeyboardFocus =
            shouldPreserveKeyboardDuringReconnect
            && session.connectionState.isConnecting
            && terminalView.shouldRestoreKeyboardFocusOnReconnect
        let shouldKeepExistingKeyboardFocus = terminalView.isFirstResponder && shouldRestoreKeyboardFocus
        let shouldAutoCaptureKeyboardFocus = session.connectionState.isConnected || shouldRestoreKeyboardFocus
        terminalView.acceptsTerminalInput = session.connectionState.isConnected
        let shouldStartSSHConnection: Bool = {
            switch session.connectionState {
            case .connecting, .reconnecting, .connected:
                return true
            case .disconnected:
                return isActive && autoReconnectEnabled
            case .failed, .idle:
                return false
            }
        }()
        if context.coordinator.isTerminalReady
            && shellMissing
            && context.coordinator.shellTask == nil
            && !shellStartInFlight
            && shouldStartSSHConnection
            && scenePhase == .active
            && !ConnectionSessionManager.shared.isSuspendingForBackground {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak terminalView] in
                guard let terminalView else { return }
                guard ConnectionSessionManager.shared.sessions.contains(where: { $0.id == session.id }) else { return }
                guard ConnectionSessionManager.shared.shellId(for: session) == nil else { return }
                guard !ConnectionSessionManager.shared.isShellStartInFlight(for: session.id) else { return }
                if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                    terminalView.resetTerminalForReconnect()
                }
                coordinator.startSSHConnection(terminal: terminalView)
            }
        }

        // Keep the terminal from reclaiming focus while an overlay (for example
        // the disconnected card) should be interactive above it.
        if shouldRenderTerminal && context.coordinator.isTerminalReady && shouldAutoCaptureKeyboardFocus {
            if terminalView.window != nil && !terminalView.isFirstResponder {
                _ = terminalView.becomeFirstResponder()
            }
        } else if scenePhase == .active
            && terminalView.isFirstResponder
            && !shouldKeepExistingKeyboardFocus {
            _ = terminalView.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }

        // Check if session still exists - if it does, user just navigated away
        // Keep terminal alive for when they come back
        let sessionStillExists = ConnectionSessionManager.shared.sessions.contains { $0.id == coordinator.sessionId }

        if sessionStillExists {
            // Session still active - user just navigated away
            // Pause rendering but keep everything alive
            terminalView.pauseRendering()
            _ = terminalView.resignFirstResponder()

            // Mark coordinator to not cleanup in deinit
            // IMPORTANT: Do NOT set terminalView = nil here!
            // The SSH output loop checks terminalView != nil to continue running.
            // Setting it to nil would break the loop and close the connection.
            coordinator.preserveSession = true
            return
        }

        // Session was closed - full cleanup
        ConnectionSessionManager.shared.unregisterShellCancelHandler(for: coordinator.sessionId)
        ConnectionSessionManager.shared.unregisterShellSuspendHandler(for: coordinator.sessionId)
        coordinator.terminalView = nil
        ConnectionSessionManager.shared.unregisterTerminal(for: coordinator.sessionId)
        coordinator.cancelShell()
    }

    // MARK: - Coordinator

    class Coordinator: SSHTerminalCoordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        private let richPasteRuntime: TerminalRichPasteRuntime
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// Tracks whether the terminal surface has been created and is ready for interaction
        var isTerminalReady = false

        /// If true, session is still active and we shouldn't cleanup on deinit (user just navigated away)
        var preserveSession = false
        var wasActive = false
        var lastReportedSize: CGSize = .zero

        init(
            server: Server,
            credentials: ServerCredentials,
            sessionId: UUID,
            onProcessExit: @escaping () -> Void,
            sshClient: SSHClient,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
            self.richPasteRuntime = .connectionSession(
                sessionId: sessionId,
                sshClient: sshClient,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        // MARK: - SSHTerminalCoordinator hooks

        func onShellStarted(terminal: GhosttyTerminalView) async {
            await applyWorkingDirectoryIfNeeded()
            await MainActor.run {
                terminal.forceRefresh()
            }
        }

        private func applyWorkingDirectoryIfNeeded() async {
            guard ConnectionSessionManager.shared.shouldApplyWorkingDirectory(for: sessionId) else { return }
            guard let cwd = ConnectionSessionManager.shared.workingDirectory(for: sessionId) else { return }
            let environment = await sshClient.remoteEnvironment()
            guard environment.supportsWorkingDirectoryRestore else { return }
            guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(for: cwd, environment: environment).data(using: .utf8) else { return }
            if let shellId {
                try? await sshClient.write(payload, to: shellId)
            }
        }

        deinit {
            // Don't cleanup if session is still active (user just navigated away)
            guard !preserveSession else { return }
            cancelShell()
        }
    }
}
#endif
