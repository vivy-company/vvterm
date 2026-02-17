import SwiftUI

struct TerminalSnippetLibraryView: View {
    @StateObject private var preferences = TerminalAccessoryPreferencesManager.shared

    @State private var showingCreateSheet = false
    @State private var editingSnippet: TerminalSnippet?

    var body: some View {
        Form {
            Section {
                if preferences.snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.snippets) { snippet in
                        Button {
                            editingSnippet = snippet
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(snippet.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(snippet.sendMode.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(snippet.content.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Edit") {
                                editingSnippet = snippet
                            }
                            .tint(.blue)

                            Button("Delete", role: .destructive) {
                                preferences.deleteSnippet(id: snippet.id)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let snippets = preferences.snippets
                        for index in offsets {
                            guard snippets.indices.contains(index) else { continue }
                            preferences.deleteSnippet(id: snippets[index].id)
                        }
                    }
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text(
                    "\(preferences.snippets.count)/\(TerminalAccessoryProfile.maxSnippets) snippets. Tap a row to edit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Manage Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!preferences.canCreateSnippet)
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            TerminalSnippetFormView()
        }
        .sheet(item: $editingSnippet) { snippet in
            TerminalSnippetFormView(snippet: snippet)
        }
    }
}
