#if os(iOS)
import SwiftUI

struct SessionsScreen: View {
    @ObservedObject var serverManager: ServerManager
    let tabManager: TerminalTabManager
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let selectedServerID: UUID
    let onOpen: (Server) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                SessionListSection(servers: serverManager.servers.filter {
                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                        || $0.host.localizedCaseInsensitiveContains(search)
                }, tabManager: tabManager, fileTabs: fileTabs, fileBrowser: fileBrowser, selectedServerID: selectedServerID, onOpen: onOpen)
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("vvterm.sessions.switcher")
            .searchable(text: $search, prompt: "Search servers")
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetDismissButton(fallbackLabel: .icon) { dismiss() }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}
#endif
