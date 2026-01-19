//
//  ContentView.swift
//  VVTerm
//

import SwiftUI

struct ContentView: View {
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var tabManager = TerminalTabManager.shared
    @StateObject private var storeManager = StoreManager.shared

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Whether the selected server is connected
    private var isSelectedServerConnected: Bool {
        guard let selected = selectedServer else { return false }
        return tabManager.connectedServerIds.contains(selected.id)
    }

    /// Whether we have any connected servers
    private var hasConnectedServers: Bool {
        !tabManager.connectedServerIds.isEmpty
    }

    @ViewBuilder
    private var detailContent: some View {
        if let server = selectedServer {
            // A server is selected
            if isSelectedServerConnected {
                // Server is connected - show its terminal container
                ConnectionTerminalContainer(
                    tabManager: tabManager,
                    serverManager: serverManager,
                    server: server
                )
                .id(server.id) // Ensure isolation per server
            } else if !hasConnectedServers {
                // Not connected to any server - can connect freely
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else if storeManager.isPro {
                // Pro user already connected to other servers - can connect to more
                ServerConnectEmptyState(server: server) {
                    connectToServer(server)
                }
            } else {
                // Free user already connected to different server - show upgrade
                MultiConnectionUpgradeEmptyState(server: server)
            }
        } else {
            // Nothing selected
            NoServerSelectedEmptyState()
        }
    }

    private func connectToServer(_ server: Server) {
        tabManager.connectedServerIds.insert(server.id)
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
            // RIGHT: Detail view based on selection state
            detailContent
        }
        .onAppear {
            // Select first workspace
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        .onChange(of: selectedServer) { _ in
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
