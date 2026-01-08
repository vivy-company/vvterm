//
//  SSHTerminalWrapper.swift
//  VivyTerm
//
//  SwiftUI wrapper for Ghostty terminal with SSH connections
//

import SwiftUI
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
        Task.detached(priority: .userInitiated) { [sshClient, logger] in
            do {
                try await sshClient.write(data)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }
    }

    func cancelShell() {
        shellTask?.cancel()
        shellTask = nil

        // Immediately abort SSH connection to unblock any pending I/O
        sshClient.abort()

        // Disconnect SSH in background to cleanup resources
        Task.detached(priority: .high) { [sshClient] in
            await sshClient.disconnect()
        }

        // Cleanup terminal to break retain cycles and release resources
        if let terminal = terminalView {
            terminal.cleanup()
        }
        terminalView = nil
    }

    func startSSHConnection(terminal: GhosttyTerminalView) {
        shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal] in
            guard let self = self, let terminal = terminal else { return }

            let sshClient = self.sshClient
            let server = self.server
            let credentials = self.credentials
            let sessionId = self.sessionId
            let onProcessExit = self.onProcessExit
            let logger = self.logger

            do {
                logger.info("Connecting to \(server.host)...")
                _ = try await sshClient.connect(to: server, credentials: credentials)

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    ConnectionSessionManager.shared.registerSSHClient(sshClient, for: sessionId)
                }

                let size = await terminal.terminalSize()
                let cols = Int(size?.columns ?? 80)
                let rows = Int(size?.rows ?? 24)

                // Platform-specific hook before shell start
                await self.onBeforeShellStart(cols: cols, rows: rows)

                let outputStream = try await sshClient.startShell(cols: cols, rows: rows)

                guard !Task.isCancelled else { return }

                // Platform-specific hook after shell starts
                await self.onShellStarted(terminal: terminal)

                // Read data in background, feed to terminal on main thread
                // CVDisplayLink in GhosttyTerminalView handles frame-rate batching
                for await data in outputStream {
                    guard !Task.isCancelled else { break }

                    // Feed data to terminal - display link batches rendering
                    let shouldContinue = await MainActor.run { [weak self] () -> Bool in
                        guard self?.terminalView != nil else { return false }
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
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("SSH connection failed: \(error.localizedDescription)")
                let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                if let data = errorMsg.data(using: .utf8) {
                    await MainActor.run {
                        terminal.feedData(data)
                    }
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

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        Coordinator(server: server, credentials: credentials, sessionId: session.id, onProcessExit: onProcessExit)
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
                    if let client = ConnectionSessionManager.shared.sshClient(for: session) {
                        try? await client.resize(cols: cols, rows: rows)
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

        let sshClient = SSHClient()
        var shellTask: Task<Void, Never>?
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHTerminal")

        /// Last known terminal size to detect changes
        private var lastSize: (cols: Int, rows: Int) = (0, 0)

        /// If true, this coordinator is reusing an existing terminal and should NOT cleanup on deinit
        var isReusingTerminal = false

        init(server: Server, credentials: ServerCredentials, sessionId: UUID, onProcessExit: @escaping () -> Void) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
        }

        /// Handle terminal resize notification from GhosttyTerminalView
        func handleResize(cols: Int, rows: Int) {
            guard cols > 0 && rows > 0 else { return }
            guard cols != lastSize.cols || rows != lastSize.rows else { return }

            lastSize = (cols, rows)
            logger.info("Terminal resized to \(cols)x\(rows)")

            Task {
                do {
                    try await sshClient.resize(cols: cols, rows: rows)
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

/// SwiftUI wrapper that uses GeometryReader to get proper size (matches official Ghostty pattern)
struct SSHTerminalWrapper: View {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void

    var body: some View {
        GeometryReader { geo in
            SSHTerminalRepresentable(
                session: session,
                server: server,
                credentials: credentials,
                size: geo.size,
                isActive: isActive,
                onProcessExit: onProcessExit,
                onReady: onReady
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

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        Coordinator(server: server, credentials: credentials, sessionId: session.id, onProcessExit: onProcessExit)
    }

    func makeUIView(context: Context) -> UIView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            // App not ready yet - show loading indicator
            let placeholder = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            placeholder.backgroundColor = .black

            let label = UILabel()
            label.text = "Loading terminal..."
            label.textColor = .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            placeholder.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor)
            ])

            return placeholder
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this session (reuse to save memory)
        // Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
        if let existingTerminal = ConnectionSessionManager.shared.getTerminal(for: session.id) {
            coordinator.terminalView = existingTerminal

            // Re-register handlers in case coordinator changed
            ConnectionSessionManager.shared.registerShellCancelHandler({ [weak coordinator] in
                coordinator?.cancelShell()
            }, for: session.id)

            return existingTerminal
        }

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: size),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            if let terminalView = terminalView {
                coordinator?.startSSHConnection(terminal: terminalView)
            }
        }
        terminalView.onProcessExit = onProcessExit

        // Store terminal reference
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

        return terminalView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let terminalView = uiView as? GhosttyTerminalView else { return }

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

        // Pass size from SwiftUI GeometryReader to terminal (matches official Ghostty pattern)
        // This is critical - SwiftUI determines the size, we pass it to Ghostty
        terminalView.sizeDidChange(size)

        // Only capture keyboard focus when terminal is active (not hidden behind stats view)
        if isActive {
            if terminalView.window != nil && !terminalView.isFirstResponder {
                _ = terminalView.becomeFirstResponder()
            }
        } else {
            if terminalView.isFirstResponder {
                terminalView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Unregister cancel handler since we're handling cleanup here
        ConnectionSessionManager.shared.unregisterShellCancelHandler(for: coordinator.sessionId)

        // CRITICAL: Unregister terminal from session manager to release strong reference
        ConnectionSessionManager.shared.unregisterTerminal(for: coordinator.sessionId)

        // Critical: Cancel SSH shell task immediately to prevent blocking
        coordinator.cancelShell()

        // Remove terminal from view hierarchy
        if let terminalView = uiView as? GhosttyTerminalView {
            // Pause rendering immediately so the back gesture animation can complete.
            terminalView.pauseRendering()
            terminalView.resignFirstResponder()

            // Cleanup is now called synchronously in cancelShell() which calls terminal.cleanup()
            // The asyncAfter cleanup is kept as a safety net for edge cases
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminalView] in
                guard let terminalView = terminalView else { return }
                terminalView.cleanup()  // Safe to call multiple times
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

        let sshClient = SSHClient()
        var shellTask: Task<Void, Never>?
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHTerminal")

        init(server: Server, credentials: ServerCredentials, sessionId: UUID, onProcessExit: @escaping () -> Void) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
        }

        // MARK: - SSHTerminalCoordinator hooks

        func onShellStarted(terminal: GhosttyTerminalView) async {
            // Force refresh after shell starts (must be on main thread)
            await MainActor.run {
                terminal.forceRefresh()
            }
        }

        deinit {
            cancelShell()
        }
    }
}
#endif
