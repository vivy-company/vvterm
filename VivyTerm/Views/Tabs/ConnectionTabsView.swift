import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Connection Tabs Scroll View

struct ConnectionTabsScrollView: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    let onNew: () -> Void

    @State private var isNewTabHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Navigation arrows group
            HStack(spacing: 4) {
                NavigationArrowButton(
                    icon: "chevron.left",
                    action: { sessionManager.selectPreviousSession() },
                    help: "Previous tab"
                )
                .disabled(sessionManager.sessions.count <= 1)

                NavigationArrowButton(
                    icon: "chevron.right",
                    action: { sessionManager.selectNextSession() },
                    help: "Next tab"
                )
                .disabled(sessionManager.sessions.count <= 1)
            }
            .padding(.leading, 8)

            // Tabs scroll view
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessionManager.sessions, id: \.id) { session in
                        ConnectionTabButton(
                            session: session,
                            isSelected: sessionManager.selectedSessionId == session.id,
                            onSelect: { sessionManager.selectSession(session) },
                            onClose: { sessionManager.closeSession(session) }
                        )
                        .contextMenu { tabContextMenu(session) }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: 600, maxHeight: 36)

            // New tab button (styled like Aizen)
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    #if os(macOS)
                    .background(
                        isNewTabHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                        in: Circle()
                    )
                    #else
                    .background(
                        isNewTabHovering ? Color.gray.opacity(0.3) : Color.clear,
                        in: Circle()
                    )
                    #endif
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { isNewTabHovering = $0 }
            #endif
            .help("New connection")
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func tabContextMenu(_ session: ConnectionSession) -> some View {
        Button("Close Terminal") {
            sessionManager.closeSession(session)
        }

        Divider()

        Button("Close All to the Left") {
            sessionManager.closeSessionsToLeft(of: session)
        }
        Button("Close All to the Right") {
            sessionManager.closeSessionsToRight(of: session)
        }
        Button("Close Other Tabs") {
            sessionManager.closeOtherSessions(except: session)
        }

        Divider()

        Button("Duplicate Tab") {
            duplicateTab(session)
        }
    }

    private func duplicateTab(_ session: ConnectionSession) {
        guard let server = sessionManager.sessions
            .first(where: { $0.id == session.id })
            .flatMap({ s in ServerManager.shared.servers.first { $0.id == s.serverId } })
        else { return }
        Task { try? await sessionManager.openConnection(to: server, forceNew: true) }
    }
}

// MARK: - Connection Tab Button

struct ConnectionTabButton: View {
    let session: ConnectionSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                // Close button (like Aizen's DetailCloseButton)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)

                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                // Title
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            #if os(macOS)
            .background(
                isSelected ?
                Color(nsColor: .separatorColor) :
                (isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear),
                in: Capsule()
            )
            #else
            .background(
                isSelected ?
                Color.gray.opacity(0.4) :
                (isHovering ? Color.gray.opacity(0.2) : Color.clear),
                in: Capsule()
            )
            #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .idle: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - Navigation Arrow Button

struct NavigationArrowButton: View {
    let icon: String
    let action: () -> Void
    var help: String = ""

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                #if os(macOS)
                .background(
                    isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                    in: Circle()
                )
                #else
                .background(
                    isHovering ? Color.gray.opacity(0.3) : Color.clear,
                    in: Circle()
                )
                #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .help(help)
    }
}

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    let serverManager: ServerManager
    let selectedServer: Server?

    /// Selected view type (stats/terminal) - stats is default
    @State private var selectedView: String = "stats"

    /// Cached terminal background color from theme
    @State private var terminalBackgroundColor: Color?

    /// Theme name from settings
    @AppStorage("terminalThemeName") private var terminalThemeName = "Aizen Dark"

    /// Disconnect confirmation
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        ZStack {
            // Stats view - always in hierarchy, visibility controlled by opacity
            if let server = selectedServer {
                ServerStatsView(server: server, session: sessionManager.selectedSession ?? dummySession(for: server))
                    .opacity(selectedView == "stats" ? 1 : 0)
                    .allowsHitTesting(selectedView == "stats")
                    .zIndex(selectedView == "stats" ? 1 : 0)
            }

            // Terminal sessions - always in hierarchy to persist state
            ForEach(sessionManager.sessions, id: \.id) { session in
                let isVisible = selectedView == "terminal" && sessionManager.selectedSessionId == session.id
                TerminalContainerView(session: session, server: server(for: session))
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .zIndex(isVisible ? 1 : 0)
            }

            // Empty state when in terminal view with no sessions
            if selectedView == "terminal" && sessionManager.sessions.isEmpty {
                TerminalEmptyStateView(server: selectedServer) {
                    if let server = selectedServer {
                        Task { try? await sessionManager.openConnection(to: server, forceNew: true) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selectedView == "terminal" ? terminalBackgroundColor : nil)
        .onAppear {
            terminalBackgroundColor = getTerminalBackgroundColor()
        }
        .onChange(of: terminalThemeName) { _, _ in
            terminalBackgroundColor = getTerminalBackgroundColor()
        }
        #if os(macOS)
        .toolbar {
            viewPickerToolbarItem
            // Only show tabs in terminal view when there are sessions
            if selectedView == "terminal" && !sessionManager.sessions.isEmpty {
                sessionTabsToolbarItem
            }
            toolbarSpacer
            disconnectToolbarItem
        }
        #endif
    }

    /// Dummy session for stats view when no real sessions exist
    private func dummySession(for server: Server) -> ConnectionSession {
        ConnectionSession(serverId: server.id, title: server.name, connectionState: .connected)
    }

    private func server(for session: ConnectionSession) -> Server? {
        serverManager.servers.first { $0.id == session.serverId }
    }

    // MARK: - Theme Background Color

    private func getTerminalBackgroundColor() -> Color? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        // Try structured path first
        let structuredThemesPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        var themeFile = (structuredThemesPath as NSString).appendingPathComponent(terminalThemeName)

        // Fall back to temp directory where themes are copied at runtime
        if !FileManager.default.fileExists(atPath: themeFile) {
            let tempThemesPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ghostty_themes")
            themeFile = (tempThemesPath as NSString).appendingPathComponent(terminalThemeName)
        }

        // Fall back to flattened resources (theme file directly in bundle)
        if !FileManager.default.fileExists(atPath: themeFile) {
            themeFile = (resourcePath as NSString).appendingPathComponent(terminalThemeName)
        }

        guard let content = try? String(contentsOfFile: themeFile, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("background") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let colorHex = parts[1].trimmingCharacters(in: .whitespaces)
                    return Color.fromHex(colorHex)
                }
            }
        }

        return nil
    }

    // MARK: - Toolbar Items (macOS)

    #if os(macOS)
    @ToolbarContentBuilder
    private var viewPickerToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("View", selection: $selectedView) {
                Label("Stats", systemImage: "chart.bar.xaxis")
                    .tag("stats")
                Label("Terminal", systemImage: "terminal")
                    .tag("terminal")
            }
            .pickerStyle(.segmented)
        }
    }

    @ToolbarContentBuilder
    private var sessionTabsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            ConnectionTabsScrollView(sessionManager: sessionManager) {
                // Use selectedServer if available, otherwise use current session's server
                let serverToConnect = selectedServer ?? currentSessionServer
                if let server = serverToConnect {
                    Task { try? await sessionManager.openConnection(to: server, forceNew: true) }
                }
            }
        }
    }

    private var currentSessionServer: Server? {
        guard let session = sessionManager.selectedSession else { return nil }
        return serverManager.servers.first { $0.id == session.serverId }
    }

    @ToolbarContentBuilder
    private var toolbarSpacer: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var disconnectToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }

        ToolbarItem(placement: .primaryAction) {
            // Disconnect button
            Button {
                showingDisconnectConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .help("Disconnect from server")
            .confirmationDialog(
                "Disconnect from \(selectedServer?.name ?? "server")?",
                isPresented: $showingDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    sessionManager.disconnectAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All terminal sessions will be closed.")
            }
        }
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

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    let session: ConnectionSession
    let server: Server?
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @State private var isReady = false
    @State private var errorMessage: String?
    @State private var credentials: ServerCredentials?

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
                            onProcessExit: {
                                ConnectionSessionManager.shared.closeSession(session)
                            },
                            onReady: {
                                isReady = true
                            }
                        )
                        .opacity(isReady ? 1 : 0)
                        .onAppear {
                            ConnectionSessionManager.shared.getTerminal(for: session.id)?.resumeRendering()
                        }
                        .onDisappear {
                            ConnectionSessionManager.shared.getTerminal(for: session.id)?.pauseRendering()
                        }
                    }

                    if !isReady || ghosttyApp.readiness != .ready {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            if ghosttyApp.readiness == .error {
                                Text("Terminal initialization failed")
                                    .foregroundStyle(.red)
                            } else {
                                Text("Initializing terminal...")
                                    .foregroundStyle(.secondary)
                            }
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
            terminalBackgroundColor = getTerminalBackgroundColor() ?? .black
        }
        .onChange(of: terminalThemeName) { _, _ in
            terminalBackgroundColor = getTerminalBackgroundColor() ?? .black
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
        .help("Voice input (⌘⇧M)")
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

    // MARK: - Theme Background Color

    private func getTerminalBackgroundColor() -> Color? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        // Try structured path first
        let structuredThemesPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        var themeFile = (structuredThemesPath as NSString).appendingPathComponent(terminalThemeName)

        // Fall back to temp directory where themes are copied at runtime
        if !FileManager.default.fileExists(atPath: themeFile) {
            let tempThemesPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ghostty_themes")
            themeFile = (tempThemesPath as NSString).appendingPathComponent(terminalThemeName)
        }

        // Fall back to flattened resources (theme file directly in bundle)
        if !FileManager.default.fileExists(atPath: themeFile) {
            themeFile = (resourcePath as NSString).appendingPathComponent(terminalThemeName)
        }

        // Try temp config directory
        if !FileManager.default.fileExists(atPath: themeFile) {
            let tempDir = NSTemporaryDirectory()
            let ghosttyConfigDir = (tempDir as NSString).appendingPathComponent(".config/ghostty/themes")
            themeFile = (ghosttyConfigDir as NSString).appendingPathComponent(terminalThemeName)
        }

        guard let content = try? String(contentsOfFile: themeFile, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("background") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let colorHex = parts[1].trimmingCharacters(in: .whitespaces)
                    return Color.fromHex(colorHex)
                }
            }
        }

        return nil
    }
}
