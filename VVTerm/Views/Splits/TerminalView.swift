//
//  TerminalView.swift
//  VVTerm
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true

    @StateObject private var audioService = AudioService()
    @State private var showingVoiceRecording = false
    @State private var voiceProcessing = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    @State private var keyMonitor: Any?

    private var dividerColor: Color {
        ThemeColorParser.splitDividerColor(for: effectiveThemeName)
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
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
        .alert("Close this terminal?", isPresented: $showingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Close", role: .destructive) {
                closeCurrentPane()
            }
            .keyboardShortcut(.defaultAction)
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
        tabManager.updatePaneState(paneId, connectionState: .disconnected)
        Task {
            await tabManager.unregisterSSHClient(for: paneId)
        }
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
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var isReady = false
    @State private var credentials: ServerCredentials?
    @State private var connectionError: String?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var dismissFallbackBanner = false
    @State private var reconnectInFlight = false
    @State private var terminalBackgroundColor: Color = .black
    @State private var connectWatchdogToken = UUID()

    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true

    private var paneState: TerminalPaneState? {
        TerminalTabManager.shared.paneStates[paneId]
    }

    private var connectionState: ConnectionState {
        paneState?.connectionState ?? .idle
    }

    /// Should this pane actually have focus (both tab selected AND pane focused)
    private var shouldFocus: Bool {
        isTabSelected && isFocused
    }

    /// Check if terminal already exists (reuse case)
    private var terminalExists: Bool {
        TerminalTabManager.shared.getTerminal(for: paneId) != nil
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        guard paneState?.activeTransport == .sshFallback else { return nil }
        guard !dismissFallbackBanner else { return nil }
        return paneState?.moshFallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    private var shouldPromptMoshInstall: Bool {
        guard server.connectionMode == .mosh else { return false }
        guard paneState?.activeTransport == .sshFallback else { return false }
        return paneState?.moshFallbackReason == .serverMissing
    }

    private var shouldShowMoshDurabilityHint: Bool {
        guard server.connectionMode == .mosh else { return false }
        return paneState?.tmuxStatus == .off
    }

    var body: some View {
        ZStack {
            terminalBackgroundColor

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

            let displayError = connectionError
            if let error = displayError {
                TerminalStatusCard {
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
                    .multilineTextAlignment(.center)
                }
            } else {
                switch connectionState {
                case .connecting:
                    TerminalStatusCard {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text(String(format: String(localized: "Connecting to %@..."), server.name))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .multilineTextAlignment(.center)
                    }
                case .reconnecting(let attempt):
                    TerminalStatusCard {
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text(String(format: String(localized: "Reconnecting (attempt %lld)..."), Int64(attempt)))
                                .foregroundStyle(.orange)
                        }
                        .multilineTextAlignment(.center)
                    }
                case .disconnected:
                    TerminalStatusCard {
                        VStack(spacing: 16) {
                            Image(systemName: "bolt.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Disconnected")
                                .foregroundStyle(.secondary)
                            if paneState?.tmuxStatus.indicatesTmux == true {
                                Text("tmux session is still running on the server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if shouldShowMoshDurabilityHint {
                                Text("Without tmux, app backgrounding can interrupt running commands.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Button("Reconnect") {
                                retryConnection()
                            }
                            .buttonStyle(.bordered)
                        }
                        .multilineTextAlignment(.center)
                    }
                case .failed(let error):
                    TerminalStatusCard {
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
                        .multilineTextAlignment(.center)
                    }
                case .connected, .idle:
                    if !isReady && !terminalExists {
                        TerminalStatusCard {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text(String(format: String(localized: "Connecting to %@..."), server.name))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .multilineTextAlignment(.center)
                        }
                    }
                }
            }

            if paneState?.tmuxStatus == .installing {
                TerminalStatusCard {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Installing tmux...")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }

            if isInstallingMosh {
                TerminalStatusCard {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Installing mosh-server...")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }

            if let fallbackBannerMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .foregroundStyle(.orange)
                        Text(fallbackBannerMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            dismissFallbackBanner = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss fallback message")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    Spacer()
                }
            }

            if showsVoiceButton && isFocused && isTabSelected && connectionState.isConnected {
                voiceTriggerButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .opacity(isFocused ? 1.0 : 0.7)
        .clipped()
        .task {
            updateTerminalBackgroundColor()
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
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
            startConnectWatchdog()
            attemptAutoReconnectIfNeeded()
        }
        .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
        .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
        .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: isReady) { _ in
            connectWatchdogToken = UUID()
            startConnectWatchdog()
        }
        .onChange(of: connectionState) { state in
            if state.isConnecting || state.isConnected {
                reconnectInFlight = false
                connectWatchdogToken = UUID()
                startConnectWatchdog()
            } else if case .disconnected = state {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: paneState?.tmuxStatus) { status in
            if status == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .onChange(of: paneState?.moshFallbackReason) { _ in
            if paneState?.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: paneState?.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: paneState?.activeTransport == .sshFallback ? paneState?.moshFallbackReason : nil) {
            guard paneState?.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
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
        .alert("Install mosh-server?", isPresented: $showingMoshInstallPrompt) {
            Button("Install") {
                Task {
                    await installMoshServerAndReconnect()
                }
            }
            Button("Continue with SSH", role: .cancel) {}
        } message: {
            Text("Mosh is selected for this server, but mosh-server is missing on the host.")
        }
    }

    private func disableTmuxForServer() {
        TerminalTabManager.shared.disableTmux(for: server.id)
    }

    private func attemptAutoReconnectIfNeeded() {
        guard scenePhase == .active else { return }
        guard autoReconnectEnabled else { return }
        guard !reconnectInFlight else { return }
        guard connectionState == .disconnected else { return }
        retryConnection()
    }

    private func retryConnection() {
        guard !reconnectInFlight else { return }
        guard !connectionState.isConnecting else { return }
        connectionError = nil
        isReady = false
        if credentials == nil {
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
            } catch {
                connectionError = String(localized: "Failed to load credentials")
                return
            }
        }
        reconnectInFlight = true
        TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
        connectWatchdogToken = UUID()
        startConnectWatchdog()
        reconnectToken = UUID()
        Task {
            await TerminalTabManager.shared.unregisterSSHClient(for: paneId)
            await MainActor.run {
                reconnectInFlight = false
            }
        }
    }

    private func startConnectWatchdog() {
        let shouldWatchConnecting = connectionState.isConnecting
        let shouldWatchConnectedNoTerminal = connectionState.isConnected && !isReady && !terminalExists
        guard shouldWatchConnecting || shouldWatchConnectedNoTerminal else { return }
        let token = connectWatchdogToken
        Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard token == connectWatchdogToken else { return }
                let stillConnecting = connectionState.isConnecting
                let stillConnectedWithoutTerminal = connectionState.isConnected && !isReady && !terminalExists
                guard stillConnecting || stillConnectedWithoutTerminal else { return }

                if stillConnectedWithoutTerminal {
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .disconnected)
                    retryConnection()
                    return
                }

                if TerminalTabManager.shared.shellId(for: paneId) != nil {
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                    return
                }

                let inFlight = TerminalTabManager.shared.isShellStartInFlight(for: paneId)
                if inFlight {
                    // Keep polling while a shell start is still in flight so stale locks
                    // and hung attempts are eventually surfaced to the user.
                    startConnectWatchdog()
                    return
                }

                TerminalTabManager.shared.updatePaneState(
                    paneId,
                    connectionState: .failed(String(localized: "Connection timed out. Please retry."))
                )
            }
        }
    }

    @MainActor
    private func installMoshServerAndReconnect() async {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        defer { isInstallingMosh = false }

        do {
            try await TerminalTabManager.shared.installMoshServer(for: paneId)
            connectionError = nil
            retryConnection()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)
            await MainActor.run {
                if let color = resolved {
                    terminalBackgroundColor = color
                    UserDefaults.standard.set(color.toHex(), forKey: "terminalBackgroundColor")
                } else {
                    terminalBackgroundColor = Color(NSColor.windowBackgroundColor)
                }
            }
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
            existingTerminal.onPwdChange = { [paneId] rawDirectory in
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
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
        terminalView.onPwdChange = { [paneId] rawDirectory in
            TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
        }

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
        // Use a dedicated SSH client per pane to avoid channel contention
        // and startup races when many panes/tabs are opened quickly.
        let client = SSHClient()
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
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHPane")

        init(server: Server, credentials: ServerCredentials, onProcessExit: @escaping () -> Void, sshClient: SSHClient) {
            self.server = server
            self.credentials = credentials
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
        }

        func sendToSSH(_ data: Data) {
            guard let shellId else { return }
            Task(priority: .userInitiated) { [sshClient, logger, shellId] in
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
            if shellTask != nil {
                logger.debug("Ignoring duplicate start request for pane")
                return
            }

            guard let paneId = self.paneId else {
                logger.error("Cannot start SSH connection without paneId")
                return
            }

            if let existingShellId = TerminalTabManager.shared.shellId(for: paneId) {
                shellId = existingShellId
                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
                return
            }

            if shellId != nil {
                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                logger.debug("Shell already active for pane")
                return
            }

            guard TerminalTabManager.shared.tryBeginShellStart(
                for: paneId,
                client: sshClient
            ) else {
                if TerminalTabManager.shared.shellId(for: paneId) != nil {
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                }
                logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
                return
            }

            let sshClient = self.sshClient
            let server = self.server
            let credentials = self.credentials
            let onProcessExit = self.onProcessExit
            let logger = self.logger

            shellTask = Task.detached(priority: .userInitiated) { [weak self, weak terminal, sshClient, server, credentials, paneId, onProcessExit, logger] in
                defer {
                    Task { @MainActor [weak self] in
                        TerminalTabManager.shared.finishShellStart(for: paneId, client: sshClient)
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
                            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
                        } else {
                            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .reconnecting(attempt: attempt))
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

                        let tmuxStartup = await TerminalTabManager.shared.tmuxStartupPlan(
                            for: paneId,
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

                        await TerminalTabManager.shared.registerSSHClient(
                            sshClient,
                            shellId: shell.id,
                            for: paneId,
                            serverId: server.id,
                            transport: shell.transport,
                            fallbackReason: shell.fallbackReason,
                            skipTmuxLifecycle: tmuxStartup.skipTmuxLifecycle
                        )
                        await MainActor.run {
                            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                            self.shellId = shell.id
                        }

                        await self.applyWorkingDirectoryIfNeeded(paneId: paneId, shellId: shell.id, sshClient: sshClient)

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

                        if attempt < maxAttempts, let sshError = error as? SSHError {
                            var shouldResetClient = false
                            switch sshError {
                            case .notConnected, .connectionFailed, .socketError, .timeout:
                                shouldResetClient = true
                            case .channelOpenFailed, .shellRequestFailed:
                                let hasOtherRegistrations = await MainActor.run {
                                    TerminalTabManager.shared.hasOtherRegistrations(
                                        using: sshClient,
                                        excluding: paneId
                                    )
                                }
                                shouldResetClient = !hasOtherRegistrations
                            case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed:
                                break
                            case .unknown:
                                break
                            }

                            if shouldResetClient {
                                logger.warning("Resetting SSH client before retrying pane connection")
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
                        TerminalTabManager.shared.updatePaneState(paneId, connectionState: .failed(lastError.localizedDescription))
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

        private func applyWorkingDirectoryIfNeeded(paneId: UUID, shellId: UUID, sshClient: SSHClient) async {
            guard TerminalTabManager.shared.shouldApplyWorkingDirectory(for: paneId) else { return }
            guard let cwd = TerminalTabManager.shared.workingDirectory(for: paneId) else { return }
            guard let payload = cdCommand(for: cwd).data(using: .utf8) else { return }
            try? await sshClient.write(payload, to: shellId)
        }

        private func cdCommand(for path: String) -> String {
            let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "cd -- '\(escaped)'\n"
        }

        deinit {
            guard !isReusingTerminal else { return }
            guard terminal == nil else { return }
            cancelShell()
        }
    }
}

#endif
