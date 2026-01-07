//
//  ConnectionTabsView.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

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
            terminalBackgroundColor = ThemeColorParser.backgroundColor(for: terminalThemeName)
        }
        .onChange(of: terminalThemeName) { _, _ in
            terminalBackgroundColor = ThemeColorParser.backgroundColor(for: terminalThemeName)
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
