#if os(iOS)
import SwiftUI

struct SessionDetailsView: View {
    let entry: SessionListEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(entry.title)
                Text(entry.statusLabel).foregroundStyle(.secondary)
            }
            ForEach(entry.panes) { pane in
                Section(pane.title) {
                    Text(pane.status.label)
                    Text(verbatim: pane.transport.rawValue)
                    if !pane.remoteSession.isEmpty { Text(pane.remoteSession) }
                }
            }
            if let path = entry.path { Section("Path") { Text(path).textSelection(.enabled) } }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                SheetDismissButton(fallbackLabel: .icon) { dismiss() }
                .accessibilityLabel("Close")
            }
        }
    }
}

#endif
