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
    @State private var showingSplitPaneUpgradeAlert = false

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
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
        .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
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
        guard StoreManager.shared.isPro else {
            showingSplitPaneUpgradeAlert = true
            return
        }
        guard tabManager.splitHorizontal(tab: tab, paneId: tab.focusedPaneId) != nil else { return }
        layoutVersion += 1
    }

    func splitVertical() {
        guard StoreManager.shared.isPro else {
            showingSplitPaneUpgradeAlert = true
            return
        }
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
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: 500)
        .adaptiveGlass()
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
            handleMonitoredKeyDown(event)
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleMonitoredKeyDown(_ event: NSEvent) -> NSEvent? {
        handleVoiceShortcut(event)
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

        guard MacTerminalShortcut.toggleVoiceRecording.matches(event) else {
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
    @State private var credentialLoadErrorMessage: String?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var operationNotice: NoticeItem?
    @State private var dismissFallbackBanner = false
    @State private var reconnectInFlight = false
    @State private var terminalBackgroundColor: Color = Self.initialTerminalBackgroundColor()
    @State private var connectWatchdogToken = UUID()
    @State private var hasEstablishedConnection = false
    @StateObject private var richPasteUI = TerminalRichPasteUIModel()

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
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

    private var shouldUseInlineReconnectPresentation: Bool {
        hasEstablishedConnection && terminalExists && connectionState.isConnecting
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(backgroundColor: terminalBackgroundColor)
    }

    private var reconnectBannerMessage: String? {
        guard shouldUseInlineReconnectPresentation else { return nil }

        if case .reconnecting(let attempt) = connectionState {
            return String(format: String(localized: "Reconnecting (attempt %lld)…"), Int64(attempt))
        }

        return String(localized: "Reconnecting…")
    }

    private var topBannerNotice: NoticeItem? {
        if let reconnectBannerMessage {
            return NoticeItem(
                id: "pane-reconnect-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .activity,
                message: reconnectBannerMessage
            )
        }

        if let fallbackBannerMessage {
            return NoticeItem(
                id: "pane-fallback-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .icon("arrow.trianglehead.2.clockwise"),
                message: fallbackBannerMessage,
                dismissAction: { dismissFallbackBanner = true }
            )
        }

        return richPasteUI.topBannerNotice
    }

    private var bottomOperationNotice: NoticeItem? {
        if paneState?.tmuxStatus == .installing {
            return NoticeItem(
                id: "pane-tmux-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing tmux"),
                message: String(localized: "Preparing persistent shell support.")
            )
        }

        if isInstallingMosh {
            return NoticeItem(
                id: "pane-mosh-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing mosh-server"),
                message: String(localized: "Preparing the remote host for Mosh.")
            )
        }

        if let operationNotice {
            return operationNotice
        }

        return richPasteUI.bottomOperationNotice
    }

    private var voiceTriggerBottomInset: CGFloat {
        bottomOperationNotice == nil ? 0 : 104
    }

    var body: some View {
        NoticeHost(
            topBanner: topBannerNotice,
            bottomOperation: bottomOperationNotice,
            bannerSurfaceStyle: noticeSurfaceStyle,
            operationSurfaceStyle: noticeSurfaceStyle
        ) {
            ZStack {
                terminalBackgroundColor

                if ghosttyApp.readiness == .ready, let credentials = credentials {
                    SSHTerminalPaneWrapper(
                        paneId: paneId,
                        server: server,
                        credentials: credentials,
                        richPasteUIModel: richPasteUI,
                        isActive: shouldFocus,
                        onProcessExit: onProcessExit,
                        onReady: { isReady = true }
                    )
                    .id(reconnectToken)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
                }

                blockingOverlay

                if showsVoiceButton && isFocused && isTabSelected && connectionState.isConnected {
                    voiceTriggerButton
                        .padding(.bottom, voiceTriggerBottomInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            }
        }
        .opacity(isFocused ? 1.0 : 0.7)
        .clipped()
        .task {
            updateTerminalBackgroundColor()
            // If terminal exists, mark ready immediately
            if terminalExists {
                isReady = true
                hasEstablishedConnection = true
            }
            if connectionState.isConnected {
                hasEstablishedConnection = true
            }
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
                credentialLoadErrorMessage = nil
            } catch {
                credentialLoadErrorMessage = String(localized: "Failed to load credentials")
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
                if terminalExists {
                    hasEstablishedConnection = true
                }
                if state.isConnected {
                    hasEstablishedConnection = true
                }
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
        .terminalRichPastePrompt(using: richPasteUI)
    }

    @ViewBuilder
    private var blockingOverlay: some View {
        if let credentialLoadErrorMessage {
            BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Connection Failed")
                        .font(.headline)
                    Text(credentialLoadErrorMessage)
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
                if !shouldUseInlineReconnectPresentation {
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
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
            case .reconnecting:
                if !shouldUseInlineReconnectPresentation {
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Reconnecting...")
                                .foregroundStyle(.orange)
                        }
                        .multilineTextAlignment(.center)
                    }
                }
            case .disconnected:
                BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
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
                BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
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
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
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
        credentialLoadErrorMessage = nil
        operationNotice = nil
        isReady = false
        if credentials == nil {
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
                credentialLoadErrorMessage = nil
            } catch {
                credentialLoadErrorMessage = String(localized: "Failed to load credentials")
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
            operationNotice = nil
            retryConnection()
        } catch {
            operationNotice = NoticeItem(
                id: "pane-mosh-install-error-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .error,
                leading: .icon("xmark.octagon.fill"),
                title: String(localized: "mosh-server install failed"),
                message: error.localizedDescription,
                dismissAction: { operationNotice = nil }
            )
        }
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)!
            await MainActor.run {
                terminalBackgroundColor = resolved
                UserDefaults.standard.set(resolved.toHex(), forKey: "terminalBackgroundColor")
            }
        }
    }

    private static func initialTerminalBackgroundColor() -> Color {
        let defaults = UserDefaults.standard

        if let cachedHex = defaults.string(forKey: "terminalBackgroundColor") {
            return Color.fromHex(cachedHex)
        }

        let usePerAppearanceTheme = defaults.object(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) as? Bool ?? true
        let darkThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let lightThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) ?? "Aizen Light"
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let themeName = usePerAppearanceTheme ? (isDarkAppearance ? darkThemeName : lightThemeName) : darkThemeName

        return ThemeColorParser.backgroundColor(for: themeName)!
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
    let richPasteUIModel: TerminalRichPasteUIModel
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
            coordinator.installRichPasteInterception(on: existingTerminal)

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
        coordinator.installRichPasteInterception(on: terminalView)
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
                let paneId = paneId
                let serverId = server.id
                DispatchQueue.main.async {
                    guard context.coordinator.focusRequestID == focusRequestID,
                          TerminalTabManager.shared.shouldGrantTerminalFocus(to: paneId, for: serverId),
                          let window = terminalView.window,
                          window.firstResponder !== terminalView else { return }
                    window.makeFirstResponder(terminalView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        // Use a dedicated SSH client per pane to avoid channel contention
        // and startup races when many panes/tabs are opened quickly.
        let client = SSHClient()
        return Coordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            onProcessExit: onProcessExit,
            sshClient: client,
            richPasteUIModel: richPasteUIModel
        )
    }

    class Coordinator {
        let paneId: UUID
        let server: Server
        let credentials: ServerCredentials
        let onProcessExit: () -> Void
        weak var terminal: GhosttyTerminalView?
        let sshClient: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        var isReusingTerminal = false
        var wasActive = false
        var lastWindowIdentity: ObjectIdentifier?
        var focusRequestID: UInt = 0
        private let richPasteRuntime: TerminalRichPasteRuntime
        private var lastSize: (cols: Int, rows: Int) = (0, 0)
        private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHPane")

        init(
            paneId: UUID,
            server: Server,
            credentials: ServerCredentials,
            onProcessExit: @escaping () -> Void,
            sshClient: SSHClient,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.paneId = paneId
            self.server = server
            self.credentials = credentials
            self.onProcessExit = onProcessExit
            self.sshClient = sshClient
            self.richPasteRuntime = .terminalPane(
                paneId: paneId,
                sshClient: sshClient,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
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

            let paneId = self.paneId

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
                await SSHConnectionRunner.run(
                    server: server,
                    credentials: credentials,
                    sshClient: sshClient,
                    terminal: terminal,
                    logger: logger,
                    onAttempt: { attempt in
                        await MainActor.run {
                            if attempt == 1 {
                                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
                            } else {
                                TerminalTabManager.shared.updatePaneState(paneId, connectionState: .reconnecting(attempt: attempt))
                            }
                        }
                    },
                    startupPlan: {
                        await TerminalTabManager.shared.tmuxStartupPlan(
                            for: paneId,
                            serverId: server.id,
                            client: sshClient
                        )
                    },
                    registerShell: { shell, skipTmuxLifecycle in
                        await TerminalTabManager.shared.registerSSHClient(
                            sshClient,
                            shellId: shell.id,
                            for: paneId,
                            serverId: server.id,
                            transport: shell.transport,
                            fallbackReason: shell.fallbackReason,
                            skipTmuxLifecycle: skipTmuxLifecycle
                        )
                        await MainActor.run {
                            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                            self.shellId = shell.id
                        }
                        await self.applyWorkingDirectoryIfNeeded(paneId: paneId, shellId: shell.id, sshClient: sshClient)
                    },
                    onBeforeShellStart: { cols, rows in
                        await MainActor.run {
                            self.lastSize = (cols, rows)
                        }
                    },
                    onShellStarted: { _, _ in },
                    shouldContinueStreaming: { data, terminal in
                        await MainActor.run { [weak self] in
                            guard self?.terminal != nil else { return false }
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
                                TerminalTabManager.shared.hasOtherRegistrations(
                                    using: sshClient,
                                    excluding: paneId
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
                            TerminalTabManager.shared.updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
                        }
                    }
                )
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
            let environment = await sshClient.remoteEnvironment()
            guard environment.supportsWorkingDirectoryRestore else { return }
            guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(for: cwd, environment: environment).data(using: .utf8) else { return }
            try? await sshClient.write(payload, to: shellId)
        }

        deinit {
            guard !isReusingTerminal else { return }
            guard terminal == nil else { return }
            cancelShell()
        }
    }
}

#endif
