#if os(iOS)
import SwiftUI

/// Shared by the server list, the session switcher, and the iPad sidebar.
struct SessionListSection: View {
    let servers: [Server]
    let tabManager: TerminalTabManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    @ObservedObject var fileBrowser: RemoteFileBrowserStore
    let selectedServerID: UUID?
    let onOpen: (Server) -> Void
    @ObservedObject private var sessionState: TerminalSessionStateStore
    @ObservedObject private var titles: TerminalPaneTitleStore
    @ObservedObject private var viewSelections: ConnectionViewSelectionStore
    @EnvironmentObject private var appLock: AppLockManager
    @EnvironmentObject private var teleportSignIn: TeleportConnectionSignInCoordinator
    @State private var collapsed: Set<UUID> = []
    @State private var requestedDestination: SessionDestination?
    @State private var presentation: Presentation?
    @ScaledMetric(relativeTo: .subheadline) private var sectionIconSize = 16

    private enum Presentation {
        case details(SessionListEntry)
        case removal(Removal)

        var details: SessionListEntry? {
            guard case .details(let entry) = self else { return nil }
            return entry
        }

        var removal: Removal? {
            guard case .removal(let removal) = self else { return nil }
            return removal
        }
    }

    private enum Removal {
        case tab(SessionDestination)
        case server(UUID)
    }

    init(servers: [Server], tabManager: TerminalTabManager,
         fileTabs: RemoteFileTabManager, fileBrowser: RemoteFileBrowserStore,
         selectedServerID: UUID? = nil,
         onOpen: @escaping (Server) -> Void) {
        self.servers = servers
        self.tabManager = tabManager
        self.fileTabs = fileTabs
        self.fileBrowser = fileBrowser
        self.selectedServerID = selectedServerID
        self.onOpen = onOpen
        _sessionState = ObservedObject(wrappedValue: tabManager.sessionState)
        _titles = ObservedObject(wrappedValue: tabManager.titleStore)
        _viewSelections = ObservedObject(wrappedValue: tabManager.connectionViewSelections)
    }

    private var actions: SessionListActions {
        SessionListActions(tabManager: tabManager, fileTabs: fileTabs, fileBrowser: fileBrowser)
    }

    private var groups: [(server: Server, entries: [SessionListEntry])] {
        servers.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }.compactMap { server in
            let entries = SessionListEntry.entries(server: server, tabManager: tabManager,
                                                  fileTabs: fileTabs, fileBrowser: fileBrowser)
            return entries.isEmpty ? nil : (server, entries)
        }
    }

    var body: some View {
        ForEach(groups, id: \.server.id) { group in
            serverSection(server: group.server, entries: group.entries)
        }
        .task(id: requestedDestination) {
            guard let destination = requestedDestination else { return }
            defer { if requestedDestination == destination { requestedDestination = nil } }
            guard let server = servers.first(where: { $0.id == destination.serverID }),
                  await authorizeOpen(server), !Task.isCancelled,
                  actions.select(destination) else { return }
            onOpen(server)
        }
        .sheet(item: Binding(
            get: { presentation?.details },
            set: { presentation = $0.map(Presentation.details) }
        )) { entry in
            NavigationStack { SessionDetailsView(entry: entry) }
        }
        .alert(removalTitle, isPresented: Binding(
            get: { presentation?.removal != nil },
            set: { if !$0 { presentation = nil } }
        ), presenting: presentation?.removal) { removal in
            Button(removalTitle, role: .destructive) { remove(removal) }
                .accessibilityIdentifier("vvterm.sessions.confirmRemoval")
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            switch removal {
            case .tab: Text("This closes only this tab. Other tabs remain open.")
            case .server: Text("All terminal and file tabs for this server will be closed.")
            }
        }
    }

    private func authorizeOpen(_ server: Server) async -> Bool {
        if server.connectionMode == .teleport,
           !sessionState.navigationState.connectedServerIds.contains(server.id) {
            return await teleportSignIn.ensureAccess(for: server) {
                await appLock.ensureServerUnlocked($0)
            }
        }
        return await appLock.ensureServerUnlocked(server)
    }

    @ViewBuilder
    private func serverSection(server: Server, entries: [SessionListEntry]) -> some View {
        let expanded = Binding(
            get: { !collapsed.contains(server.id) },
            set: { if $0 { collapsed.remove(server.id) } else { collapsed.insert(server.id) } }
        )
        if #available(iOS 17.0, *) {
            Section(isExpanded: expanded) {
                sessionRows(entries)
            } header: {
                serverHeading(server)
            }
        } else {
            Section {
                if expanded.wrappedValue { sessionRows(entries) }
            } header: {
                Button {
                    withAnimation { expanded.wrappedValue.toggle() }
                } label: {
                    HStack {
                        serverHeading(server)
                        Spacer()
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func serverHeading(_ server: Server) -> some View {
        Label {
            Text(server.name)
        } icon: {
            ServerIconView(server: server, size: sectionIconSize)
        }
            .textCase(nil)
            .accessibilityIdentifier("vvterm.sessions.server.\(server.id)")
            .contextMenu {
                Button(role: .destructive) { presentation = .removal(.server(server.id)) } label: {
                    Label("Disconnect Server", systemImage: "power")
                }
            }
    }

    private func sessionRows(_ entries: [SessionListEntry]) -> some View {
        ForEach(entries) { entry in
            Button { requestedDestination = entry.id } label: {
                SessionListRow(
                    entry: entry,
                    isSelected: isSelected(entry)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("vvterm.sessions.tab.\(entry.id.tabID)")
            .accessibilityAddTraits(isSelected(entry) ? .isSelected : [])
            .contextMenu {
                Button { presentation = .details(entry) } label: { Label("Details", systemImage: "info.circle") }
                Button(role: .destructive) { presentation = .removal(.tab(entry.id)) } label: {
                    Label("Close Tab", systemImage: "xmark")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Only the confirmation deletes the tab. A destructive swipe action
                // makes List remove and restore the row while confirmation is pending.
                Button { presentation = .removal(.tab(entry.id)) } label: {
                    Label("Close Tab", systemImage: "xmark")
                }
                .tint(.red)
            }
        }
    }

    private var removalTitle: String {
        switch presentation?.removal { case .server: String(localized: "Disconnect Server"); default: String(localized: "Close Tab") }
    }

    private func isSelected(_ entry: SessionListEntry) -> Bool {
        guard entry.id.serverID == selectedServerID else { return false }
        guard viewSelections.selection(for: entry.id.serverID) == entry.id.view else { return false }
        switch entry.id {
        case .terminal(let serverID, let tabID): return sessionState.selectedTabId(for: serverID) == tabID
        case .files(let serverID, let tabID): return fileTabs.selectedTab(for: serverID)?.id == tabID
        }
    }

    private func remove(_ removal: Removal) {
        switch removal {
        case .tab(let destination): actions.close(destination)
        case .server(let id):
            actions.disconnect(serverID: id)
        }
    }
}

#endif
