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
import Foundation
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
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true

    @StateObject private var audioService = AudioService()
    @State private var showingVoiceRecording = false
    @State private var voiceProcessing = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    @State private var keyMonitor: Any?

    private var dividerColor: Color {
        ThemeColorParser.splitDividerColor(for: terminalThemeName)
    }

    private var focusedTerminal: GhosttyTerminalView? {
        TerminalTabManager.shared.getTerminal(for: tab.focusedPaneId)
    }

    private var hasFocusedTerminal: Bool {
        focusedTerminal != nil
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
            // Refresh when terminals register/unregister so overlays can update immediately.
            let _ = tabManager.terminalRegistryVersion
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
                    onProcessExit: { handlePaneExit(paneId: tab.rootPaneId) },
                    showsVoiceButton: isSelected
                        && voiceButtonEnabled
                        && !showingVoiceRecording
                        && hasFocusedTerminal,
                    onVoiceTrigger: { startVoiceRecording() }
                )
            }

            if isSelected && hasFocusedTerminal {
                if showingVoiceRecording {
                    voiceOverlay
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        .onAppear {
            updateKeyMonitor()
        }
        .onChange(of: isSelected) { _ in
            updateKeyMonitor()
            if !isSelected, showingVoiceRecording {
                audioService.cancelRecording()
                showingVoiceRecording = false
                voiceProcessing = false
            }
        }
        .onDisappear {
            cleanupKeyMonitor()
            if showingVoiceRecording {
                audioService.cancelRecording()
                showingVoiceRecording = false
                voiceProcessing = false
            }
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
                    onProcessExit: { handlePaneExit(paneId: paneId) },
                    showsVoiceButton: isSelected
                        && voiceButtonEnabled
                        && !showingVoiceRecording
                        && tab.focusedPaneId == paneId
                        && hasFocusedTerminal,
                    onVoiceTrigger: { startVoiceRecording() }
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
        guard tabManager.splitHorizontal(tab: tab, paneId: tab.focusedPaneId) != nil else { return }
        layoutVersion += 1
    }

    func splitVertical() {
        guard tabManager.splitVertical(tab: tab, paneId: tab.focusedPaneId) != nil else { return }
        layoutVersion += 1
    }

    func closeCurrentPane() {
        tabManager.closePane(tab: tab, paneId: tab.focusedPaneId)
    }

    // MARK: - Voice Input (macOS)

    private var voiceOverlay: some View {
        VoiceRecordingView(
            audioService: audioService,
            onSend: { transcribedText in
                sendTranscriptionToTerminal(transcribedText)
                showingVoiceRecording = false
                voiceProcessing = false
            },
            onCancel: {
                showingVoiceRecording = false
                voiceProcessing = false
            },
            isProcessing: $voiceProcessing
        )
        .padding(12)
        .frame(maxWidth: 520)
        .adaptiveGlass()
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(16)
    }

    private func updateKeyMonitor() {
        if isSelected {
            setupKeyMonitor()
        } else {
            cleanupKeyMonitor()
        }
    }

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            handleVoiceShortcut(event)
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleVoiceShortcut(_ event: NSEvent) -> NSEvent? {
        guard isSelected else { return event }

        let keyCodeEscape: UInt16 = 53
        let keyCodeReturn: UInt16 = 36

        if showingVoiceRecording {
            if event.keyCode == keyCodeEscape {
                audioService.cancelRecording()
                showingVoiceRecording = false
                voiceProcessing = false
                return nil
            }
            if event.keyCode == keyCodeReturn {
                toggleVoiceRecording()
                return nil
            }
        }

        // Check for Cmd+Shift+M
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.shift),
              event.charactersIgnoringModifiers?.lowercased() == "m" else {
            return event
        }
        toggleVoiceRecording()
        return nil
    }

    private func toggleVoiceRecording() {
        if showingVoiceRecording {
            Task {
                let text = await audioService.stopRecording()
                await MainActor.run {
                    let fallback = text.isEmpty ? audioService.partialTranscription : text
                    sendTranscriptionToTerminal(fallback)
                    showingVoiceRecording = false
                    voiceProcessing = false
                }
            }
        } else {
            startVoiceRecording()
        }
    }

    private func startVoiceRecording() {
        Task {
            do {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showingVoiceRecording = true
                }
                try await audioService.startRecording()
            } catch {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showingVoiceRecording = false
                }
                voiceProcessing = false
                if let recordingError = error as? AudioService.RecordingError {
                    permissionErrorMessage = recordingError.localizedDescription
                        + "\n\n"
                        + String(localized: "Enable Microphone and Speech Recognition in System Settings.")
                } else {
                    permissionErrorMessage = error.localizedDescription
                }
                showingPermissionError = true
            }
        }
    }

    private func sendTranscriptionToTerminal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let terminal = focusedTerminal else { return }
        DispatchQueue.main.async {
            terminal.sendText(trimmed)
        }
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
    let showsVoiceButton: Bool
    let onVoiceTrigger: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    @State private var isReady = false
    @State private var credentials: ServerCredentials?
    @State private var connectionError: String?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false

    private var paneState: TerminalPaneState? {
        TerminalTabManager.shared.paneStates[paneId]
    }

    private var paneConnectionError: String? {
        guard let state = paneState?.connectionState else { return nil }
        if case .failed(let message) = state {
            return message
        }
        return nil
    }

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
                .id(reconnectToken)
                .contentShape(Rectangle())
                .onTapGesture { onFocus() }
            }

            let displayError = connectionError ?? paneConnectionError
            if let error = displayError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Connection Failed")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        retryConnection()
                    }
                    .buttonStyle(.bordered)
                }
            } else if !isReady && !terminalExists {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text(String(format: String(localized: "Connecting to %@..."), server.name))
                        .foregroundStyle(.secondary)
                }
            }

            if paneState?.tmuxStatus == .installing {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Installing tmux...")
                        .foregroundStyle(.secondary)
                }
            }

            if showsVoiceButton && isFocused && isTabSelected {
                voiceTriggerButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
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

            if paneState?.tmuxStatus == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .onChange(of: paneState?.tmuxStatus) { status in
            if status == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                Task {
                    await TerminalTabManager.shared.startTmuxInstall(for: paneId)
                }
            }
            Button("Continue without persistence", role: .cancel) {
                disableTmuxForServer()
            }
        } message: {
            Text("tmux keeps your terminal session alive across app restarts and disconnects.")
        }
    }

    private func disableTmuxForServer() {
        var updatedServer = server
        updatedServer.tmuxEnabledOverride = false
        TerminalTabManager.shared.disableTmux(for: server.id)
        Task {
            try? await ServerManager.shared.updateServer(updatedServer)
        }
    }

    private func retryConnection() {
        connectionError = nil
        isReady = false
        TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
        reconnectToken = UUID()
        Task {
            await TerminalTabManager.shared.unregisterSSHClient(for: paneId)
        }
    }

    private var voiceTriggerButton: some View {
        Button {
            onVoiceTrigger()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Voice input (Command+Shift+M)"))
        .padding(14)
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
                    if let client = TerminalTabManager.shared.getSSHClient(for: paneId),
                       let shellId = TerminalTabManager.shared.shellId(for: paneId) {
                        try? await client.resize(cols: cols, rows: rows, for: shellId)
                    }
                }
            }
            existingTerminal.writeCallback = { [paneId] data in
                if let client = TerminalTabManager.shared.getSSHClient(for: paneId),
                   let shellId = TerminalTabManager.shared.shellId(for: paneId) {
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

            DispatchQueue.main.async {
                onReady()
                if TerminalTabManager.shared.shellId(for: paneId) == nil {
                    coordinator.startSSHConnection(terminal: existingTerminal)
                }
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
        let client = TerminalTabManager.shared.sharedSSHClient(for: server)
        return Coordinator(server: server, credentials: credentials, onProcessExit: onProcessExit, sshClient: client)
    }

    class Coordinator {
        let server: Server
        let credentials: ServerCredentials
        let onProcessExit: () -> Void
        weak var terminal: GhosttyTerminalView?
        var paneId: UUID?
        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        var isReusingTerminal = false
        var wasActive = false
        private var lastSize: (cols: Int, rows: Int) = (0, 0)
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHPane")

        init(server: Server, credentials: ServerCredentials, onProcessExit: @escaping () -> Void, sshClient: SSHClient) {
            self.server = server
            self.credentials = credentials
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
        }

        func sendToSSH(_ data: Data) {
            guard let shellId else { return }
            Task.detached(priority: .userInitiated) { [sshClient, logger, shellId] in
                do {
                    try await sshClient.write(data, to: shellId)
                } catch {
                    logger.error("Failed to send to SSH: \(error.localizedDescription)")
                }
            }
        }

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

        func startSSHConnection(terminal: GhosttyTerminalView) {
            let sshClient = self.sshClient
            let server = self.server
            let credentials = self.credentials
            let paneId = self.paneId
            let onProcessExit = self.onProcessExit
            let logger = self.logger

            shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal, sshClient, server, credentials, paneId, onProcessExit, logger] in
                guard let self = self, let terminal = terminal else { return }

                let maxAttempts = 3
                var lastError: Error?

                for attempt in 1...maxAttempts {
                    guard !Task.isCancelled else { return }

                    if let paneId = paneId {
                        await MainActor.run {
                            if attempt == 1 {
                                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
                            } else {
                                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .reconnecting(attempt: attempt))
                            }
                        }
                    }

                    do {
                        logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                        _ = try await sshClient.connect(to: server, credentials: credentials)

                        guard !Task.isCancelled else { return }

                        let size = await terminal.terminalSize()
                        let cols = Int(size?.columns ?? 80)
                        let rows = Int(size?.rows ?? 24)

                        // Store initial size
                        await MainActor.run {
                            self.lastSize = (cols, rows)
                        }

                        let shell = try await sshClient.startShell(cols: cols, rows: rows)

                        if let paneId = paneId {
                            await TerminalTabManager.shared.registerSSHClient(sshClient, shellId: shell.id, for: paneId, serverId: server.id)
                            await MainActor.run {
                                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                            }
                        }

                        await MainActor.run {
                            self.shellId = shell.id
                        }

                        guard !Task.isCancelled else { return }

                        // Read data in background, feed to terminal
                        for await data in shell.stream {
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
                    if let paneId = paneId {
                        await MainActor.run {
                            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .failed(lastError.localizedDescription))
                        }
                    }
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
