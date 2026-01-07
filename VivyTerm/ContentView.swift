//
//  ContentView.swift
//  VivyTerm
//

import SwiftUI

struct ContentView: View {
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var sessionManager = ConnectionSessionManager.shared
    @StateObject private var storeManager = StoreManager.shared

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Server we're connected to (from connectedServerId)
    private var connectedServer: Server? {
        guard let id = sessionManager.connectedServerId else { return nil }
        return serverManager.servers.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // LEFT: Sidebar with workspace + servers
            ServerSidebarView(
                serverManager: serverManager,
                selectedWorkspace: $selectedWorkspace,
                selectedServer: $selectedServer,
                selectedEnvironment: $selectedEnvironment
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            // RIGHT: Terminal with toolbar tabs
            if sessionManager.connectedServerId != nil {
                // Connected to a server - show terminal container (handles empty state internally)
                ConnectionTerminalContainer(
                    sessionManager: sessionManager,
                    serverManager: serverManager,
                    selectedServer: selectedServer ?? connectedServer
                )
            } else if let server = selectedServer {
                // Not connected - show connect button
                ServerConnectEmptyState(server: server) {
                    Task { try? await sessionManager.openConnection(to: server) }
                }
            } else {
                NoServerSelectedEmptyState()
            }
        }
        .onAppear {
            // Select first workspace
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
        .onChange(of: serverManager.workspaces) { _, workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        .onChange(of: selectedServer) { _, server in
            // Auto-connect on selection (optional)
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
