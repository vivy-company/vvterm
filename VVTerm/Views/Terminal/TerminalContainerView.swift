//
//  TerminalContainerView.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    let session: ConnectionSession
    let server: Server?
    var isActive: Bool = true
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var errorMessage: String?
    @State private var credentials: ServerCredentials?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var dismissFallbackBanner = false
    @State private var reconnectInFlight = false
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true

    /// Check if terminal already exists (was previously created)
    private var terminalAlreadyExists: Bool {
        ConnectionSessionManager.shared.getTerminal(for: session.id) != nil
    }

    // Voice input state
    #if os(macOS) || os(iOS)
    @StateObject private var audioService = AudioService()
    @State private var showingVoiceRecording = false
    @State private var voiceProcessing = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true
    #endif

    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    /// Terminal background color from theme
    @State private var terminalBackgroundColor: Color = .black

    /// Theme name from settings
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = true

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        guard session.activeTransport == .sshFallback else { return nil }
        guard !dismissFallbackBanner else { return nil }
        return session.moshFallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    private var shouldPromptMoshInstall: Bool {
        guard server?.connectionMode == .mosh else { return false }
        guard session.activeTransport == .sshFallback else { return false }
        return session.moshFallbackReason == .serverMissing
    }

    private var shouldShowMoshDurabilityHint: Bool {
        guard server?.connectionMode == .mosh else { return false }
        return session.tmuxStatus == .off
    }

    #if os(macOS) || os(iOS)
    private var voiceTriggerHandler: (() -> Void)? {
        voiceButtonEnabled ? { handleVoiceTrigger() } : nil
    }
    #endif

    var body: some View {
        ZStack {
            #if os(iOS)
            terminalBackgroundColor
            #else
            terminalBackgroundColor.ignoresSafeArea()
            #endif

            let state = session.connectionState
            let shouldAttemptConnection = terminalAlreadyExists || state.isConnected || state.isConnecting
            let isFailedState: Bool = {
                if case .failed = state { return true }
                return false
            }()
            let hasServerAndCredentials = server != nil && credentials != nil
            let shouldShowInitializing = !terminalAlreadyExists
                && !isFailedState
                && state != .disconnected
                && (ghosttyApp.readiness != .ready || !isReady)
            let shouldShowInitializingOverlay = shouldShowInitializing && hasServerAndCredentials

            if shouldAttemptConnection {
                Color.clear
                    .onAppear {
                        ghosttyApp.startIfNeeded()
                    }
                if let server = server, let credentials = credentials {
                    // Wait for ghostty to be ready before creating terminal
                    if ghosttyApp.readiness == .ready {
                        SSHTerminalWrapper(
                            session: session,
                            server: server,
                            credentials: credentials,
                            isActive: isActive,
                            onProcessExit: {
                                ConnectionSessionManager.shared.handleShellExit(for: session.id)
                            },
                            onReady: {
                                isReady = true
                            },
                            onVoiceTrigger: voiceTriggerHandler
                        )
                        .id(reconnectToken)
                        .opacity(isReady || terminalAlreadyExists ? 1 : 0)
                        .onAppear {
                            // If terminal already exists, mark as ready immediately
                            if terminalAlreadyExists {
                                isReady = true
                            }
                            #if os(macOS)
                            ConnectionSessionManager.shared.getTerminal(for: session.id)?.resumeRendering()
                            #endif
                        }
                        #if os(macOS)
                        .onDisappear {
                            ConnectionSessionManager.shared.getTerminal(for: session.id)?.pauseRendering()
                        }
                        #endif
                    }

                    if ghosttyApp.readiness == .error {
                        TerminalStatusCard {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Terminal initialization failed")
                                    .foregroundStyle(.red)
                            }
                            .multilineTextAlignment(.center)
                        }
                    } else if shouldShowInitializingOverlay {
                        TerminalStatusCard {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Initializing terminal...")
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                        }
                    }
                }
            }

            if ghosttyApp.readiness != .error && !shouldShowInitializingOverlay {
                switch state {
                case .connecting:
                    TerminalStatusCard {
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Connecting...")
                                .foregroundStyle(.secondary)
                        }
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
                            if session.tmuxStatus.indicatesTmux {
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
                                Task { await retryConnection() }
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
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                Task { await retryConnection() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .multilineTextAlignment(.center)
                    }
                case .connected, .idle:
                    EmptyView()
                }
            }

            if session.tmuxStatus == .installing {
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

            // Error overlay
            if let error = errorMessage {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            }

            // Voice input overlays (macOS only)
            #if os(macOS)
            if session.connectionState.isConnected && isReady {
                if showingVoiceRecording {
                    voiceOverlay
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if voiceButtonEnabled {
                    voiceTriggerButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            }
            #endif
            #if os(iOS)
            if session.connectionState.isConnected && isReady && showingVoiceRecording {
                voiceOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
            #endif
        }
        .task {
            loadCredentialsIfNeeded(force: true)
        }
        .onChange(of: server?.id) { _ in
            loadCredentialsIfNeeded(force: true)
        }
        .onAppear {
            updateTerminalBackgroundColor()
            if session.tmuxStatus == .missing {
                showingTmuxInstallPrompt = true
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
            attemptAutoReconnectIfNeeded()
        }
        .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
        .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
        .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                updateTerminalBackgroundColor()
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: session.connectionState) { state in
            if state.isConnecting || state.isConnected {
                reconnectInFlight = false
            } else if case .disconnected = state {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: session.tmuxStatus) { status in
            if status == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .onChange(of: session.moshFallbackReason) { _ in
            if session.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: session.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: session.activeTransport == .sshFallback ? session.moshFallbackReason : nil) {
            guard session.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
        }
        #if os(macOS) || os(iOS)
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        #endif
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                Task {
                    await ConnectionSessionManager.shared.startTmuxInstall(for: session.id)
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
        #if os(macOS)
        .onAppear {
            setupKeyMonitor()
        }
        .onDisappear {
            cleanupKeyMonitor()
            if showingVoiceRecording {
                audioService.cancelRecording()
                showingVoiceRecording = false
                voiceProcessing = false
            }
        }
        #endif
        #if os(iOS)
        .onDisappear {
            if showingVoiceRecording {
                audioService.cancelRecording()
                showingVoiceRecording = false
                voiceProcessing = false
            }
        }
        #endif
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
                    #if os(iOS)
                    terminalBackgroundColor = Color(UIColor.systemBackground)
                    #elseif os(macOS)
                    terminalBackgroundColor = Color(NSColor.windowBackgroundColor)
                    #else
                    terminalBackgroundColor = .black
                    #endif
                }
            }
        }
    }

    private func disableTmuxForServer() {
        guard let server else { return }
        ConnectionSessionManager.shared.disableTmux(for: server.id)
    }

    private func attemptAutoReconnectIfNeeded() {
        guard scenePhase == .active else { return }
        guard !reconnectInFlight else { return }
        guard autoReconnectEnabled else { return }
        guard session.connectionState == .disconnected else { return }
        Task { await retryConnection() }
    }

    @MainActor
    private func retryConnection() async {
        guard !reconnectInFlight else { return }
        guard !session.connectionState.isConnecting else { return }
        reconnectInFlight = true
        defer { reconnectInFlight = false }
        isReady = false
        loadCredentialsIfNeeded(force: false)
        guard credentials != nil else { return }
        ghosttyApp.startIfNeeded()
        try? await ConnectionSessionManager.shared.reconnect(session: session)
        reconnectToken = UUID()
    }

    @MainActor
    private func installMoshServerAndReconnect() async {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        defer { isInstallingMosh = false }

        do {
            try await ConnectionSessionManager.shared.installMoshServer(for: session.id)
            errorMessage = nil
            await retryConnection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadCredentialsIfNeeded(force: Bool) {
        guard let server else { return }
        if !force, credentials != nil { return }
        do {
            credentials = try KeychainManager.shared.getCredentials(for: server)
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "Failed to load credentials: %@"), error.localizedDescription)
        }
    }

    // MARK: - Voice Input (macOS / iOS)

    #if os(macOS) || os(iOS)
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
    #endif

    #if os(macOS)
    private var voiceTriggerButton: some View {
        Button {
            startVoiceRecording()
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
    #endif

    #if os(macOS)
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
    #endif

    #if os(macOS) || os(iOS)
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
    #endif

    #if os(macOS) || os(iOS)
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
    #endif

    #if os(macOS) || os(iOS)
    private func handleVoiceTrigger() {
        guard session.connectionState.isConnected, isReady else { return }
        guard !showingVoiceRecording else { return }
        startVoiceRecording()
    }
    #endif

    private func sendTranscriptionToTerminal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ConnectionSessionManager.shared.sendText(trimmed, to: session.id)
    }

}

// MARK: - Terminal Empty State View

struct TerminalEmptyStateView: View {
    let server: Server?
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(server?.name ?? String(localized: "Terminal"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("No terminals open")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onNewTerminal) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Terminal")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
