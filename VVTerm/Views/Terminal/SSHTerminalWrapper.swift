//
//  SSHTerminalWrapper.swift
//  VVTerm
//
//  SwiftUI wrapper for Ghostty terminal with SSH connections
//

import SwiftUI
import Foundation
import os.log

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
        Task(priority: .userInitiated) { [sessionId, logger] in
            let route = await MainActor.run { () -> (client: SSHClient, shellId: UUID)? in
                guard let session = ConnectionSessionManager.shared.sessions.first(where: { $0.id == sessionId }),
                      let client = ConnectionSessionManager.shared.sshClient(for: session),
                      let shellId = ConnectionSessionManager.shared.shellId(for: session) else {
                    return nil
                }
                return (client: client, shellId: shellId)
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
        if let shellId {
            Task.detached(priority: .high) { [sshClient, shellId] in
                await sshClient.closeShell(shellId)
            }
        }
        self.shellId = nil
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        if shellTask != nil {
            logger.debug("Ignoring duplicate start request for session \(self.sessionId)")
            return
        }

        if let existingShellId = ConnectionSessionManager.shared.shellId(for: sessionId) {
            shellId = existingShellId
            ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
            logger.debug("Reusing existing shell for session \(self.sessionId)")
            return
        }

        if shellId != nil {
            ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
            logger.debug("Shell already active for session \(self.sessionId)")
            return
        }

        guard ConnectionSessionManager.shared.tryBeginShellStart(
            for: sessionId,
            client: sshClient
        ) else {
            if ConnectionSessionManager.shared.shellId(for: sessionId) != nil {
                ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
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

            let maxAttempts = 3
            var lastError: Error?

            for attempt in 1...maxAttempts {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    if attempt == 1 {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connecting)
                    } else {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .reconnecting(attempt: attempt))
                    }
                }

                do {
                    logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                    _ = try await sshClient.connect(to: server, credentials: credentials)

                    guard !Task.isCancelled else { return }

                    let size = await terminal.terminalSize()
                    let cols = Int(size?.columns ?? 80)
                    let rows = Int(size?.rows ?? 24)

                    // Platform-specific hook before shell start
                    await self.onBeforeShellStart(cols: cols, rows: rows)

                    let tmuxStartup = await ConnectionSessionManager.shared.tmuxStartupPlan(
                        for: sessionId,
                        serverId: server.id,
                        client: sshClient
                    )

                    let shell = try await sshClient.startShell(
                        cols: cols,
                        rows: rows,
                        startupCommand: tmuxStartup.command
                    )

                    guard !Task.isCancelled else {
                        await sshClient.closeShell(shell.id)
                        return
                    }

                    await MainActor.run { [sessionId, serverId = server.id, shellId = shell.id, transport = shell.transport, fallbackReason = shell.fallbackReason, skipTmuxLifecycle = tmuxStartup.skipTmuxLifecycle] in
                        ConnectionSessionManager.shared.registerSSHClient(
                            sshClient,
                            shellId: shellId,
                            for: sessionId,
                            serverId: serverId,
                            transport: transport,
                            fallbackReason: fallbackReason,
                            skipTmuxLifecycle: skipTmuxLifecycle
                        )
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
                    }

                    await MainActor.run {
                        self.shellId = shell.id
                    }

                    guard !Task.isCancelled else { return }

                    // Platform-specific hook after shell starts
                    await self.onShellStarted(terminal: terminal)

                    // Read data in background, feed to terminal on main thread
                    // CVDisplayLink in GhosttyTerminalView handles frame-rate batching
                    for await data in shell.stream {
                        guard !Task.isCancelled else { break }

                        // Feed data to terminal - display link batches rendering
                        // Check session manager instead of coordinator to survive view dismantling on iOS
                        let shouldContinue = await MainActor.run { () -> Bool in
                            // Session still exists = keep running (even if coordinator was deallocated)
                            let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                            guard sessionExists else { return false }
                            terminal.feedData(data)
                            return true
                        }
                        if !shouldContinue { break }
                    }

                    guard !Task.isCancelled else { return }
                    logger.info("SSH shell ended")
                    await MainActor.run {
                        onProcessExit()
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error
                    logger.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                    if attempt < maxAttempts, let sshError = error as? SSHError {
                        var shouldResetClient = false
                        switch sshError {
                        case .notConnected, .connectionFailed, .socketError, .timeout:
                            shouldResetClient = true
                        case .channelOpenFailed, .shellRequestFailed:
                            let hasOtherRegistrations = await MainActor.run {
                                ConnectionSessionManager.shared.hasOtherRegistrations(
                                    using: sshClient,
                                    excluding: sessionId
                                )
                            }
                            shouldResetClient = !hasOtherRegistrations
                        case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed:
                            break
                        case .unknown:
                            break
                        }

                        if shouldResetClient {
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
                let errorMsg = "\r\n\u{001B}[31mSSH Error: \(lastError.localizedDescription)\u{001B}[0m\r\n"
                if let data = errorMsg.data(using: .utf8) {
                    await MainActor.run {
                        terminal.feedData(data)
                    }
                }
                await MainActor.run {
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .failed(lastError.localizedDescription))
                }
            }
        }
    }

    // Default no-op implementations for hooks
    func onShellStarted(terminal: GhosttyTerminalView) async {}
    func onBeforeShellStart(cols: Int, rows: Int) async {}
}

#if os(macOS)
import AppKit

// MARK: - SSH Terminal Wrapper

struct SSHTerminalWrapper: NSViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        // Use a dedicated SSH client per tab/session to avoid channel contention
        // and startup races when many tabs are opened quickly.
        let client = SSHClient()
        return Coordinator(server: server, credentials: credentials, sessionId: session.id, onProcessExit: onProcessExit, sshClient: client)
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

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            // Terminal is already ready - call onReady immediately
            // Use async to avoid calling during view construction
            DispatchQueue.main.async {
                onReady()
                if ConnectionSessionManager.shared.shellId(for: session) == nil {
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

        // Ensure terminal has focus
        if let scrollView = nsView as? TerminalScrollView {
            let terminalView = scrollView.surfaceView
            if let window = nsView.window, window.firstResponder != terminalView {
                window.makeFirstResponder(terminalView)
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
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// Last known terminal size to detect changes
        private var lastSize: (cols: Int, rows: Int) = (0, 0)

        /// If true, this coordinator is reusing an existing terminal and should NOT cleanup on deinit
        var isReusingTerminal = false

        init(server: Server, credentials: ServerCredentials, sessionId: UUID, onProcessExit: @escaping () -> Void, sshClient: SSHClient) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
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
            guard let payload = cdCommand(for: cwd).data(using: .utf8) else { return }
            if let shellId {
                try? await sshClient.write(payload, to: shellId)
            }
        }

        private func cdCommand(for path: String) -> String {
            let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "cd -- '\(escaped)'\n"
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

// MARK: - Terminal Container View

/// Lightweight container that holds the terminal view after deferred creation
/// This allows navigation animations to complete smoothly before heavy Metal/GPU setup
final class TerminalContainerUIView: UIView {
    weak var terminalView: GhosttyTerminalView?
    var isActive = false {
        didSet {
            if isActive != oldValue {
                pendingRefresh = true
                setNeedsLayout()
            }
        }
    }
    var keyboardInset: CGFloat = 0 {
        didSet {
            if keyboardInset != oldValue {
                setNeedsLayout()
            }
        }
    }
    private var pendingRefresh = false
    private var lastLaidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func availableBoundsForTerminal() -> CGRect {
        let clampedInset = min(max(0, effectiveKeyboardInset()), bounds.height)
        return bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: clampedInset, right: 0))
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let terminalView = terminalView else { return }
        let availableBounds = availableBoundsForTerminal()
        if terminalView.frame != availableBounds {
            terminalView.frame = availableBounds
        }
        if availableBounds.size != lastLaidOutSize {
            lastLaidOutSize = availableBounds.size
            if availableBounds.width > 0 && availableBounds.height > 0 {
                terminalView.sizeDidChange(availableBounds.size)
            }
        }

        guard bounds.width > 0 && bounds.height > 0 else { return }
        if isActive && pendingRefresh {
            terminalView.forceRefresh()
            pendingRefresh = false
        }
    }

    func requestRefresh() {
        pendingRefresh = true
        setNeedsLayout()
    }

    private func effectiveKeyboardInset() -> CGFloat {
        // Prefer iOS keyboard layout guide because notification ordering can be stale
        // when the app backgrounds/foregrounds with keyboard still visible.
        if window != nil {
            let guideOverlap = bounds.intersection(keyboardLayoutGuide.layoutFrame).height
            return guideOverlap
        }
        return keyboardInset
    }
}

/// SwiftUI wrapper that uses GeometryReader to get proper size (matches official Ghostty pattern)
struct SSHTerminalWrapper: View {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            SSHTerminalRepresentable(
                session: session,
                server: server,
                credentials: credentials,
                size: geo.size,
                isActive: isActive,
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
    let size: CGSize
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        // Use a dedicated SSH client per tab/session to avoid channel contention
        // and startup races when many tabs are opened quickly.
        let client = SSHClient()
        return Coordinator(server: server, credentials: credentials, sessionId: session.id, onProcessExit: onProcessExit, sshClient: client)
    }

    func makeUIView(context: Context) -> UIView {
        let coordinator = context.coordinator

        // Check if terminal already exists for this session (reuse to save memory)
        if let existingTerminal = ConnectionSessionManager.shared.getTerminal(for: session.id) {
            coordinator.terminalView = existingTerminal
            coordinator.isTerminalReady = true
            // Mark as reusing so we don't cleanup on deinit
            coordinator.preserveSession = true
            existingTerminal.onVoiceButtonTapped = onVoiceTrigger
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }

            // Route through coordinator to preserve write ordering and transport behavior.
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                       let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                        try? await sshClient.resize(cols: cols, rows: rows, for: shellId)
                    }
                }
            }

            // Rewrap in a fresh container so layout/safe-area changes apply correctly.
            let container = TerminalContainerUIView()
            container.backgroundColor = .black
            coordinator.containerView = container
            coordinator.startKeyboardMonitoring()

            if existingTerminal.superview != nil {
                existingTerminal.removeFromSuperview()
            }
            existingTerminal.frame = container.bounds
            existingTerminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(existingTerminal)
            container.terminalView = existingTerminal
            coordinator.lastReportedSize = container.bounds.size
            if container.bounds.width > 0 && container.bounds.height > 0 {
                existingTerminal.sizeDidChange(container.bounds.size)
            }

            // Resume rendering since it was paused when navigating away
            existingTerminal.resumeRendering()

            // Force refresh after a brief delay to ensure view is in window hierarchy
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak existingTerminal, session] in
                guard let terminal = existingTerminal else { return }
                terminal.forceRefresh()

                // Also trigger SSH resize to force server to redraw prompt
                if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                   let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                    Task {
                        if let size = terminal.terminalSize() {
                            try? await sshClient.resize(cols: Int(size.columns), rows: Int(size.rows), for: shellId)
                        }
                    }
                }
            }

            onReady()
            if ConnectionSessionManager.shared.shellId(for: session) == nil {
                coordinator.startSSHConnection(terminal: existingTerminal)
            }
            return container
        }

        // Create a container view that will hold the terminal once it's ready
        // This allows the navigation animation to complete smoothly
        let container = TerminalContainerUIView()
        container.backgroundColor = .black
        coordinator.containerView = container
        coordinator.startKeyboardMonitoring()

        // Defer heavy terminal creation to after animation completes (150ms for iOS navigation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak coordinator, weak container] in
            guard let coordinator = coordinator, let container = container else { return }
            guard let app = ghosttyApp.app else { return }

            // Create terminal on main thread but after navigation animation
            let terminalView = GhosttyTerminalView(
                frame: container.bounds,
                worktreePath: NSHomeDirectory(),
                ghosttyApp: app,
                appWrapper: ghosttyApp,
                paneId: session.id.uuidString,
                useCustomIO: true
            )

            terminalView.onReady = { [weak coordinator, weak terminalView] in
                coordinator?.isTerminalReady = true
                onReady()
                if let terminalView = terminalView {
                    coordinator?.startSSHConnection(terminal: terminalView)
                }
            }
            terminalView.onProcessExit = onProcessExit
            terminalView.onVoiceButtonTapped = onVoiceTrigger
            terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }

            // Store terminal reference
            coordinator.terminalView = terminalView
            ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

            // Register shell cancel handler
            ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
                coordinator?.cancelShell()
            }, for: session.id)
            ConnectionSessionManager.shared.registerShellSuspendHandler({ [weak coordinator] in
                coordinator?.suspendShell()
            }, for: session.id)

            // Setup write callback
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

            // Add terminal to container with fade-in animation
            terminalView.frame = container.bounds
            terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            terminalView.alpha = 0
            container.addSubview(terminalView)
            container.terminalView = terminalView

            UIView.animate(withDuration: 0.15) {
                terminalView.alpha = 1
            } completion: { [weak terminalView] _ in
                // Force refresh after fade-in completes to ensure content is visible
                terminalView?.forceRefresh()
            }
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Get terminal view - either directly or from container
        let terminalView: GhosttyTerminalView?
        let isDirectTerminalView: Bool
        if let direct = uiView as? GhosttyTerminalView {
            terminalView = direct
            isDirectTerminalView = true
        } else if let container = uiView as? TerminalContainerUIView {
            terminalView = container.terminalView
            isDirectTerminalView = false
        } else {
            return
        }

        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            // Session was closed externally, cleanup terminal
            context.coordinator.cancelShell()
            terminalView?.writeCallback = nil
            terminalView?.onReady = nil
            terminalView?.onProcessExit = nil
            return
        }

        guard let terminalView = terminalView else { return }

        terminalView.onVoiceButtonTapped = onVoiceTrigger
        if isDirectTerminalView, size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            // Keep rendering even when inactive so tab switching doesn't stall frames.
            terminalView.resumeRendering()
        }

        if let container = uiView as? TerminalContainerUIView {
            container.isActive = isActive
            container.keyboardInset = context.coordinator.keyboardInset
            if isActive {
                container.requestRefresh()
            } else {
                container.setNeedsLayout()
            }
        }

        // Only capture keyboard focus when terminal is active (not hidden behind stats view)
        if isActive && context.coordinator.isTerminalReady {
            if terminalView.window != nil && !terminalView.isFirstResponder {
                _ = terminalView.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Check if session still exists - if it does, user just navigated away
        // Keep terminal alive for when they come back
        let sessionStillExists = ConnectionSessionManager.shared.sessions.contains { $0.id == coordinator.sessionId }

        // Get terminal view - either directly or from container
        let terminalView: GhosttyTerminalView?
        if let direct = uiView as? GhosttyTerminalView {
            terminalView = direct
        } else if let container = uiView as? TerminalContainerUIView {
            terminalView = container.terminalView
        } else {
            terminalView = nil
        }

        if sessionStillExists {
            // Session still active - user just navigated away
            // Pause rendering but keep everything alive
            terminalView?.pauseRendering()
            _ = terminalView?.resignFirstResponder()

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
        ConnectionSessionManager.shared.unregisterTerminal(for: coordinator.sessionId)
        coordinator.cancelShell()

        // Remove terminal from view hierarchy
        if let terminalView = terminalView {
            terminalView.pauseRendering()
            _ = terminalView.resignFirstResponder()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminalView] in
                guard let terminalView = terminalView else { return }
                terminalView.cleanup()
                terminalView.removeFromSuperview()
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
        weak var containerView: TerminalContainerUIView?

        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// Tracks whether the terminal surface has been created and is ready for interaction
        var isTerminalReady = false

        /// If true, session is still active and we shouldn't cleanup on deinit (user just navigated away)
        var preserveSession = false
        var lastReportedSize: CGSize = .zero
        var keyboardInset: CGFloat = 0
        private var keyboardObservers: [NSObjectProtocol] = []
        private var lastKeyboardFrame: CGRect = .zero

        init(server: Server, credentials: ServerCredentials, sessionId: UUID, onProcessExit: @escaping () -> Void, sshClient: SSHClient) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
        }

        func startKeyboardMonitoring() {
            guard keyboardObservers.isEmpty else { return }
            let center = NotificationCenter.default
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboardNotification(notification)
            })
            keyboardObservers.append(center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboardNotification(notification)
            })
        }

        private func handleKeyboardNotification(_ notification: Notification) {
            guard let containerView = containerView,
                  let window = containerView.window,
                  let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }

            lastKeyboardFrame = frameValue
            let keyboardFrameInWindow = window.convert(frameValue, from: nil)
            let containerFrameInWindow = containerView.convert(containerView.bounds, to: window)
            let overlap = containerFrameInWindow.intersection(keyboardFrameInWindow).height
            let newInset = max(0, overlap)

            if newInset != keyboardInset {
                keyboardInset = newInset
                containerView.keyboardInset = newInset
                containerView.setNeedsLayout()
                containerView.layoutIfNeeded()
            }
        }

        // MARK: - SSHTerminalCoordinator hooks

        func onShellStarted(terminal: GhosttyTerminalView) async {
            await applyWorkingDirectoryIfNeeded()
            // Force refresh after shell starts (must be on main thread)
            await MainActor.run { [weak self] in
                terminal.forceRefresh()

                // Additional delayed refresh to catch prompt after it arrives from server
                // Also send resize to force server to redraw prompt
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak terminal, weak self] in
                    terminal?.forceRefresh()

                    // Trigger resize to force server to redraw prompt
                    if let self = self {
                        Task {
                            if let size = terminal?.terminalSize() {
                                if let shellId = self.shellId {
                                    try? await self.sshClient.resize(cols: Int(size.columns), rows: Int(size.rows), for: shellId)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func applyWorkingDirectoryIfNeeded() async {
            guard ConnectionSessionManager.shared.shouldApplyWorkingDirectory(for: sessionId) else { return }
            guard let cwd = ConnectionSessionManager.shared.workingDirectory(for: sessionId) else { return }
            guard let payload = cdCommand(for: cwd).data(using: .utf8) else { return }
            if let shellId {
                try? await sshClient.write(payload, to: shellId)
            }
        }

        private func cdCommand(for path: String) -> String {
            let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "cd -- '\(escaped)'\n"
        }

        deinit {
            for observer in keyboardObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            // Don't cleanup if session is still active (user just navigated away)
            guard !preserveSession else { return }
            cancelShell()
        }
    }
}
#endif
