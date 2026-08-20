import SwiftUI

/// A deterministic app-shell preview with no live external dependencies.
@MainActor
struct AppPreviewComposition {
    private let workspace = Workspace(
        id: UUID(uuidString: "E6B55295-4694-4B3A-AC1D-A179399B5C09")!,
        name: "My Servers",
        colorHex: "#5AC8FA",
        order: 0,
        environments: [.production]
    )
    private let server = Server(
        id: UUID(uuidString: "CEBBE449-AFAE-44C7-99F0-F494ED6B05B4")!,
        workspaceId: UUID(uuidString: "E6B55295-4694-4B3A-AC1D-A179399B5C09")!,
        environment: .production,
        name: "Production",
        host: "example.com",
        username: "demo"
    )

    var rootView: some View {
        AppPreviewRoot(workspace: workspace, server: server)
    }
}

private struct AppPreviewRoot: View {
    let workspace: Workspace
    let server: Server

    var body: some View {
        NavigationSplitView {
            List {
                Section(workspace.name) {
                    Label(server.name, systemImage: "server.rack")
                }
            }
            .navigationTitle("VVTerm")
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text(server.name)
                    .font(.title2.bold())
                Text("$ ssh \(server.username)@\(server.host)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
        }
    }
}
