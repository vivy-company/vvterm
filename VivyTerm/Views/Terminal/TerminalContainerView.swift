//
//  TerminalContainerView.swift
//  VivyTerm
//

import SwiftUI

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    let session: ConnectionSession
    let server: Server?
    var isActive: Bool = true
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @State private var isReady = false
    @State private var errorMessage: String?
    @State private var credentials: ServerCredentials?

    /// Check if terminal already exists (was previously created)
    private var terminalAlreadyExists: Bool {
        ConnectionSessionManager.shared.getTerminal(for: session.id) != nil
    }

    // Voice input state
    #if os(macOS)
    @StateObject private var audioService = AudioService()
    @State private var showingVoiceRecording = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    @State private var keyMonitor: Any?
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true
    #endif

    /// Terminal background color from theme
    @State private var terminalBackgroundColor: Color = .black

    /// Theme name from settings
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"

    var body: some View {
        ZStack {
            terminalBackgroundColor.ignoresSafeArea()

            switch session.connectionState {
            case .connected:
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
                                ConnectionSessionManager.shared.closeSession(session)
                            },
                            onReady: {
                                isReady = true
                            }
                        )
                        .opacity(isReady || terminalAlreadyExists ? 1 : 0)
                        .onAppear {
                            // If terminal already exists, mark as ready immediately
                            if terminalAlreadyExists {
                                isReady = true
                            }
                            ConnectionSessionManager.shared.getTerminal(for: session.id)?.resumeRendering()
                        }
                        .onDisappear {
                            ConnectionSessionManager.shared.getTerminal(for: session.id)?.pauseRendering()
                        }
                    }

                    if !isReady && !terminalAlreadyExists && ghosttyApp.readiness == .ready {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Initializing terminal...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if ghosttyApp.readiness == .error {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Terminal initialization failed")
                                .foregroundStyle(.red)
                        }
                    }

                    if ghosttyApp.readiness != .ready && ghosttyApp.readiness != .error {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Initializing terminal...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Connecting...")
                        .foregroundStyle(.secondary)
                }

            case .reconnecting(let attempt):
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Reconnecting (attempt \(attempt))...")
                        .foregroundStyle(.orange)
                }

            case .disconnected:
                VStack(spacing: 16) {
                    Image(systemName: "bolt.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Disconnected")
                        .foregroundStyle(.secondary)
                    Button("Reconnect") {
                        Task { try? await ConnectionSessionManager.shared.reconnect(session: session) }
                    }
                    .buttonStyle(.bordered)
                }

            case .failed(let error):
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
                        .padding(.horizontal)
                    Button("Retry") {
                        Task { try? await ConnectionSessionManager.shared.reconnect(session: session) }
                    }
                    .buttonStyle(.bordered)
                }

            case .idle:
                // Idle state should not be reached in normal flow
                // but included for switch exhaustiveness
                EmptyView()
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
        }
        .task {
            // Load credentials from keychain when view appears
            guard let server = server else { return }
            do {
                credentials = try KeychainManager.shared.getCredentials(for: server)
            } catch {
                errorMessage = "Failed to load credentials: \(error.localizedDescription)"
            }
        }
        .onAppear {
            terminalBackgroundColor = ThemeColorParser.backgroundColor(for: terminalThemeName) ?? .black
        }
        .onChange(of: terminalThemeName) { _, _ in
            terminalBackgroundColor = ThemeColorParser.backgroundColor(for: terminalThemeName) ?? .black
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
            }
        }
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        #endif
    }

    // MARK: - Voice Input (macOS)

    #if os(macOS)
    private var voiceOverlay: some View {
        VoiceRecordingView(
            audioService: audioService,
            onSend: { transcribedText in
                sendTranscriptionToTerminal(transcribedText)
                showingVoiceRecording = false
            },
            onCancel: {
                showingVoiceRecording = false
            }
        )
        .padding(12)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(16)
    }

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
        .help("Voice input (Command+Shift+M)")
        .padding(14)
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
        let keyCodeEscape: UInt16 = 53
        let keyCodeReturn: UInt16 = 36

        if showingVoiceRecording {
            if event.keyCode == keyCodeEscape {
                audioService.cancelRecording()
                showingVoiceRecording = false
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
                if let recordingError = error as? AudioService.RecordingError {
                    permissionErrorMessage = recordingError.localizedDescription + "\n\nEnable Microphone and Speech Recognition in System Settings."
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
        ConnectionSessionManager.shared.sendText(trimmed, to: session.id)
    }
    #endif
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
                    Text(server?.name ?? "Terminal")
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
