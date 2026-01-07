//
//  SSHTerminalWrapper.swift
//  VivyTerm
//
//  SwiftUI wrapper for Ghostty terminal with SSH connections
//

import SwiftUI
import os.log
#if os(macOS)
import AppKit

// MARK: - SSH Terminal Wrapper

struct SSHTerminalWrapper: NSViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
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

        let coordinator = context.coordinator
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

    class Coordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        private let sshClient = SSHClient()
        private var shellTask: Task<Void, Never>?
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHTerminal")

        /// Last known terminal size to detect changes
        private var lastSize: (cols: Int, rows: Int) = (0, 0)

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

        func startSSHConnection(terminal: GhosttyTerminalView) {
            // Run SSH operations in background, only hop to main for UI updates
            shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal, sshClient, server, credentials, sessionId, onProcessExit, logger] in
                guard let self = self, let terminal = terminal else { return }

                do {
                    // Connect to SSH server
                    logger.info("Connecting to \(server.host)...")
                    _ = try await sshClient.connect(to: server, credentials: credentials)

                    guard !Task.isCancelled else { return }

                    // Register SSH client with session manager for stats/command access
                    await MainActor.run {
                        ConnectionSessionManager.shared.registerSSHClient(sshClient, for: sessionId)
                    }

                    // Get terminal size
                    let size = await terminal.terminalSize()
                    let cols = Int(size?.columns ?? 80)
                    let rows = Int(size?.rows ?? 24)

                    // Store initial size to avoid redundant resize on first update
                    await MainActor.run {
                        self.lastSize = (cols, rows)
                    }

                    // Start shell and read output
                    let outputStream = try await sshClient.startShell(cols: cols, rows: rows)

                    guard !Task.isCancelled else { return }

                    // Read data in background, feed to terminal on main thread
                    for await data in outputStream {
                        guard !Task.isCancelled else { break }
                        // Check if session and terminal are still valid
                        let isValid = await MainActor.run {
                            self.terminalView != nil &&
                            ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                        }
                        guard isValid else { break }
                        // Feed data on main thread
                        await MainActor.run {
                            terminal.feedData(data)
                        }
                    }

                    guard !Task.isCancelled else { return }
                    // Shell ended
                    logger.info("SSH shell ended")
                    await MainActor.run {
                        onProcessExit()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    logger.error("SSH connection failed: \(error.localizedDescription)")
                    // Show error in terminal
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        await MainActor.run {
                            terminal.feedData(data)
                        }
                    }
                }
            }
        }

        func sendToSSH(_ data: Data) {
            Task {
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
            // Clear terminal reference and callbacks to break retain cycles
            if let terminal = terminalView {
                terminal.writeCallback = nil
                terminal.onReady = nil
                terminal.onProcessExit = nil
            }
            terminalView = nil
        }

        deinit {
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
    let onProcessExit: () -> Void
    let onReady: () -> Void

    var body: some View {
        GeometryReader { geo in
            SSHTerminalRepresentable(
                session: session,
                server: server,
                credentials: credentials,
                size: geo.size,
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

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: size),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true
        )

        let coordinator = context.coordinator
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

        // Ensure terminal has focus only when visible
        if terminalView.window != nil && !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Unregister cancel handler since we're handling cleanup here
        ConnectionSessionManager.shared.unregisterShellCancelHandler(for: coordinator.sessionId)

        // Critical: Cancel SSH shell task immediately to prevent blocking
        coordinator.cancelShell()

        // Remove terminal from view hierarchy
        if let terminalView = uiView as? GhosttyTerminalView {
            // Pause rendering immediately so the back gesture animation can complete.
            terminalView.pauseRendering()
            terminalView.resignFirstResponder()

            // Defer heavy cleanup until after the pop animation finishes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminalView] in
                guard let terminalView = terminalView else { return }
                terminalView.cleanup()
                terminalView.removeFromSuperview()
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        private let sshClient = SSHClient()
        private var shellTask: Task<Void, Never>?
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHTerminal")

        init(server: Server, credentials: ServerCredentials, sessionId: UUID, onProcessExit: @escaping () -> Void) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
        }

        func startSSHConnection(terminal: GhosttyTerminalView) {
            // Run SSH operations in background, only hop to main for UI updates
            shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal, sshClient, server, credentials, sessionId, onProcessExit, logger] in
                guard let self = self, let terminal = terminal else { return }

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

                    let outputStream = try await sshClient.startShell(cols: cols, rows: rows)

                    guard !Task.isCancelled else { return }

                    // Force refresh after shell starts (must be on main thread)
                    await MainActor.run {
                        terminal.forceRefresh()
                    }

                    // Read data in background, feed to terminal on main thread
                    for await data in outputStream {
                        guard !Task.isCancelled else { break }
                        // Check if session and terminal are still valid
                        let isValid = await MainActor.run {
                            self.terminalView != nil &&
                            ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                        }
                        guard isValid else { break }
                        // Feed data on main thread
                        await MainActor.run {
                            terminal.feedData(data)
                        }
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

        func sendToSSH(_ data: Data) {
            Task {
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
            // Clear terminal reference and callbacks to break retain cycles
            if let terminal = terminalView {
                terminal.writeCallback = nil
                terminal.onReady = nil
                terminal.onProcessExit = nil
            }
            terminalView = nil
        }

        deinit {
            cancelShell()
        }
    }
}
#endif
