//
//  TerminalView.swift
//  VivyTerm
//
//  Renders a single tab's terminal content (with optional splits).
//  Each tab is isolated - splits happen within the tab, not across tabs.
//

#if os(macOS)
import SwiftUI
import AppKit
import os.log

// MARK: - Terminal Tab View

/// Renders a single terminal tab with its split layout
struct TerminalTabView: View {
    let tab: TerminalTab
    let server: Server
    @ObservedObject var tabManager: TerminalTabManager
    let isSelected: Bool

    @State private var layoutVersion: Int = 0
    @State private var showingCloseConfirmation = false

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"

    private var dividerColor: Color {
        ThemeColorParser.splitDividerColor(for: terminalThemeName)
    }

    /// Split actions for menu commands - only active when this tab is selected
    private var splitActions: TerminalSplitActions? {
        guard isSelected else { return nil }
        return TerminalSplitActions(
            splitHorizontal: { splitHorizontal() },
            splitVertical: { splitVertical() },
            closePane: { requestClosePane() }
        )
    }

    var body: some View {
        ZStack {
            if let layout = tab.layout {
                renderNode(layout)
            } else {
                // Single pane - no splits
                TerminalPaneView(
                    paneId: tab.rootPaneId,
                    server: server,
                    isFocused: true,
                    isTabSelected: isSelected,
                    onFocus: { },
                    onProcessExit: { handlePaneExit(paneId: tab.rootPaneId) }
                )
            }
        }
        .focusedValue(\.activeServerId, isSelected ? server.id : nil)
        .focusedValue(\.activePaneId, isSelected ? tab.focusedPaneId : nil)
        .focusedSceneValue(\.terminalSplitActions, splitActions)
        .onReceive(NotificationCenter.default.publisher(for: .closeTerminalPane)) { _ in
            // Only handle if this tab is selected
            if isSelected {
                requestClosePane()
            }
        }
        .confirmationDialog(
            "Close this terminal?",
            isPresented: $showingCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                closeCurrentPane()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The SSH connection will be terminated.")
        }
    }

    private func requestClosePane() {
        showingCloseConfirmation = true
    }

    // MARK: - Render Split Tree

    private func renderNode(_ node: TerminalSplitNode) -> AnyView {
        switch node {
        case .leaf(let paneId):
            return AnyView(
                TerminalPaneView(
                    paneId: paneId,
                    server: server,
                    isFocused: tab.focusedPaneId == paneId,
                    isTabSelected: isSelected,
                    onFocus: { focusPane(paneId) },
                    onProcessExit: { handlePaneExit(paneId: paneId) }
                )
                .id("\(paneId)-\(layoutVersion)")
            )

        case .split(let split):
            let currentNode = node
            let ratioBinding = Binding<CGFloat>(
                get: { CGFloat(split.ratio) },
                set: { newRatio in
                    updateRatio(node: currentNode, newRatio: Double(newRatio))
                }
            )

            return AnyView(
                SplitView(
                    split.direction == .horizontal ? .horizontal : .vertical,
                    ratioBinding,
                    dividerColor: dividerColor,
                    left: { renderNode(split.left) },
                    right: { renderNode(split.right) },
                    onEqualize: { equalizeLayout() }
                )
            )
        }
    }

    // MARK: - Actions

    private func focusPane(_ paneId: UUID) {
        var updatedTab = tab
        updatedTab.focusedPaneId = paneId
        tabManager.updateTab(updatedTab)
    }

    private func updateRatio(node: TerminalSplitNode, newRatio: Double) {
        guard var layout = tab.layout else { return }
        let updated = node.withUpdatedRatio(newRatio)
        layout = layout.replacingNode(node, with: updated)
        var updatedTab = tab
        updatedTab.layout = layout
        tabManager.updateTab(updatedTab)
    }

    private func equalizeLayout() {
        guard let layout = tab.layout else { return }
        var updatedTab = tab
        updatedTab.layout = layout.equalized()
        tabManager.updateTab(updatedTab)
    }

    private func handlePaneExit(paneId: UUID) {
        tabManager.closePane(tab: tab, paneId: paneId)
    }

    // MARK: - Split Actions

    func splitHorizontal() {
        guard let newPaneId = tabManager.splitHorizontal(tab: tab, paneId: tab.focusedPaneId) else { return }
        layoutVersion += 1
    }

    func splitVertical() {
        guard let newPaneId = tabManager.splitVertical(tab: tab, paneId: tab.focusedPaneId) else { return }
        layoutVersion += 1
    }

    func closeCurrentPane() {
        tabManager.closePane(tab: tab, paneId: tab.focusedPaneId)
    }
}

// MARK: - Terminal Pane View

/// Renders a single terminal pane (leaf in split tree)
struct TerminalPaneView: View {
    let paneId: UUID
    let server: Server
    let isFocused: Bool
    let isTabSelected: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    @State private var isReady = false
    @State private var credentials: ServerCredentials?
    @State private var connectionError: String?

    /// Should this pane actually have focus (both tab selected AND pane focused)
    private var shouldFocus: Bool {
        isTabSelected && isFocused
    }

    /// Check if terminal already exists (reuse case)
    private var terminalExists: Bool {
        TerminalTabManager.shared.getTerminal(for: paneId) != nil
    }

    var body: some View {
        ZStack {
            Color.black

            // Always render terminal when ready - no complex state checks
            // Terminal wrapper handles existence check internally
            if ghosttyApp.readiness == .ready, let credentials = credentials {
                SSHTerminalPaneWrapper(
                    paneId: paneId,
                    server: server,
                    credentials: credentials,
                    isActive: shouldFocus,
                    onProcessExit: onProcessExit,
                    onReady: { isReady = true }
                )
                .contentShape(Rectangle())
                .onTapGesture { onFocus() }
            }

            // Loading overlay while connecting (hidden once ready or terminal exists)
            if !isReady && !terminalExists {
                if let error = connectionError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Connection Failed")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Connecting to \(server.name)...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .opacity(isFocused ? 1.0 : 0.7)
        .task {
            // If terminal exists, mark ready immediately
            if terminalExists {
                isReady = true
            }
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
            } catch {
                connectionError = String(localized: "Failed to load credentials")
            }
        }
    }
}

// MARK: - SSH Terminal Pane Wrapper

/// Wraps SSH connection and Ghostty terminal for a pane
struct SSHTerminalPaneWrapper: NSViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let isActive: Bool
    let onProcessExit: () -> Void
    let onReady: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator
        coordinator.paneId = paneId

        // Check if terminal already exists for this pane (reuse to save memory)
        if let existingTerminal = TerminalTabManager.shared.getTerminal(for: paneId) {
            coordinator.isReusingTerminal = true
            coordinator.terminal = existingTerminal

            // Update resize callback to use tab manager's registered SSH client
            existingTerminal.onResize = { [paneId] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    if let client = TerminalTabManager.shared.getSSHClient(for: paneId) {
                        try? await client.resize(cols: cols, rows: rows)
                    }
                }
            }

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            DispatchQueue.main.async {
                onReady()
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
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
        coordinator.terminal = terminalView
        TerminalTabManager.shared.registerTerminal(terminalView, for: paneId)

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
        // Ensure terminal has focus when active
        if let scrollView = nsView as? TerminalScrollView {
            let terminalView = scrollView.surfaceView

            // Track active state change
            let wasActive = context.coordinator.wasActive
            context.coordinator.wasActive = isActive

            if isActive {
                // Always try to set focus when active
                if let window = nsView.window, window.firstResponder != terminalView {
                    // Use async to ensure view hierarchy is ready
                    DispatchQueue.main.async {
                        if let window = terminalView.window {
                            window.makeFirstResponder(terminalView)
                        }
                    }
                }
            }

            // If just became active, force focus
            if isActive && !wasActive {
                DispatchQueue.main.async {
                    if let window = terminalView.window {
                        window.makeFirstResponder(terminalView)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(server: server, credentials: credentials, onProcessExit: onProcessExit)
    }

    class Coordinator {
        let server: Server
        let credentials: ServerCredentials
        let onProcessExit: () -> Void
        weak var terminal: GhosttyTerminalView?
        var paneId: UUID?
        let sshClient = SSHClient()
        var shellTask: Task<Void, Never>?
        var isReusingTerminal = false
        var wasActive = false
        private var lastSize: (cols: Int, rows: Int) = (0, 0)
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHPane")

        init(server: Server, credentials: ServerCredentials, onProcessExit: @escaping () -> Void) {
            self.server = server
            self.credentials = credentials
            self.onProcessExit = onProcessExit
        }

        func sendToSSH(_ data: Data) {
            Task.detached(priority: .userInitiated) { [sshClient, logger] in
                do {
                    try await sshClient.write(data)
                } catch {
                    logger.error("Failed to send to SSH: \(error.localizedDescription)")
                }
            }
        }

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
            shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal] in
                guard let self = self, let terminal = terminal else { return }

                let sshClient = self.sshClient
                let server = self.server
                let credentials = self.credentials
                let paneId = self.paneId
                let onProcessExit = self.onProcessExit
                let logger = self.logger

                do {
                    logger.info("Connecting to \(server.host)...")
                    _ = try await sshClient.connect(to: server, credentials: credentials)

                    guard !Task.isCancelled else { return }

                    // Register SSH client with tab manager
                    if let paneId = paneId {
                        await TerminalTabManager.shared.registerSSHClient(sshClient, for: paneId)
                    }

                    let size = await terminal.terminalSize()
                    let cols = Int(size?.columns ?? 80)
                    let rows = Int(size?.rows ?? 24)

                    // Store initial size
                    await MainActor.run {
                        self.lastSize = (cols, rows)
                    }

                    let outputStream = try await sshClient.startShell(cols: cols, rows: rows)

                    guard !Task.isCancelled else { return }

                    // Read data in background, feed to terminal
                    for await data in outputStream {
                        guard !Task.isCancelled else { break }

                        let shouldContinue = await MainActor.run { [weak self] () -> Bool in
                            guard self?.terminal != nil else { return false }
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

        func cancelShell() {
            shellTask?.cancel()
            shellTask = nil

            sshClient.abort()

            Task.detached(priority: .high) { [sshClient] in
                await sshClient.disconnect()
            }

            if let terminal = terminal {
                terminal.cleanup()
            }
            terminal = nil
        }

        deinit {
            guard !isReusingTerminal else { return }
            guard terminal == nil else { return }
            cancelShell()
        }
    }
}

#endif
