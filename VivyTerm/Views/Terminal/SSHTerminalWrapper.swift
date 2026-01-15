//
//  SSHTerminalWrapper.swift
//  VivyTerm
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
        // Use high-priority detached task to minimize latency
        // Task.detached avoids inheriting actor context, reducing overhead
        guard let shellId else { return }
        Task.detached(priority: .userInitiated) { [sshClient, logger, shellId] in
            do {
                try await sshClient.write(data, to: shellId)
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

    func startSSHConnection(terminal: GhosttyTerminalView) {
        // Capture all values needed in the detached task before creating it
        // to avoid accessing main actor-isolated properties from detached context
        let sshClient = self.sshClient
        let server = self.server
        let credentials = self.credentials
        let sessionId = self.sessionId
        let onProcessExit = self.onProcessExit
        let logger = self.logger

        shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal] in
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

                    let shell = try await sshClient.startShell(cols: cols, rows: rows)

                    await MainActor.run { [sessionId, serverId = server.id, shellId = shell.id] in
                        ConnectionSessionManager.shared.registerSSHClient(sshClient, shellId: shellId, for: sessionId, serverId: serverId)
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
        let client = ConnectionSessionManager.shared.sharedSSHClient(for: server)
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
            existingTerminal.writeCallback = { data in
                if let client = ConnectionSessionManager.shared.sshClient(for: session),
                   let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                    Task.detached(priority: .userInitiated) {
                        try? await client.write(data, to: shellId)
                    }
                }
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

        // Store terminal reference in coordinator and register with session manager
        coordinator.terminalView = terminalView
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

        // Register shell cancel handler so closeSession can cancel the shell task
        ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
            coordinator?.cancelShell()
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
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHTerminal")

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
    private var pendingRefresh = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let terminalView = terminalView else { return }
        if terminalView.frame != bounds {
            terminalView.frame = bounds
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
        let client = ConnectionSessionManager.shared.sharedSSHClient(for: server)
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

            // Update write callback to use this coordinator (which will use session manager's SSH client)
            existingTerminal.writeCallback = { data in
                // Use SSH client from session manager, not coordinator's client
                if let sshClient = ConnectionSessionManager.shared.sshClient(for: session),
                   let shellId = ConnectionSessionManager.shared.shellId(for: session) {
                    Task.detached(priority: .userInitiated) {
                        try? await sshClient.write(data, to: shellId)
                    }
                }
            }

            // Rewrap in a fresh container so layout/safe-area changes apply correctly.
            let container = TerminalContainerUIView()
            container.backgroundColor = .black

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

            // Store terminal reference
            coordinator.terminalView = terminalView
            ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

            // Register shell cancel handler
            ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
                coordinator?.cancelShell()
            }, for: session.id)

            // Setup write callback
            terminalView.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            terminalView.setupWriteCallback()

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
        if let direct = uiView as? GhosttyTerminalView {
            terminalView = direct
        } else if let container = uiView as? TerminalContainerUIView {
            terminalView = container.terminalView
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
        if size.width > 0 && size.height > 0 && size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
        }

        if context.coordinator.isTerminalReady {
            // Keep rendering even when inactive so tab switching doesn't stall frames.
            terminalView.resumeRendering()
        }

        if let container = uiView as? TerminalContainerUIView {
            container.isActive = isActive
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

        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHTerminal")

        /// Tracks whether the terminal surface has been created and is ready for interaction
        var isTerminalReady = false

        /// If true, session is still active and we shouldn't cleanup on deinit (user just navigated away)
        var preserveSession = false
        var lastReportedSize: CGSize = .zero

        init(server: Server, credentials: ServerCredentials, sessionId: UUID, onProcessExit: @escaping () -> Void, sshClient: SSHClient) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
        }

        // MARK: - SSHTerminalCoordinator hooks

        func onShellStarted(terminal: GhosttyTerminalView) async {
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

        deinit {
            // Don't cleanup if session is still active (user just navigated away)
            guard !preserveSession else { return }
            cancelShell()
        }
    }
}
#endif
