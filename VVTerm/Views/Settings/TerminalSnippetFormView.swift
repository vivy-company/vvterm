import SwiftUI

struct TerminalSnippetFormView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preferences = TerminalAccessoryPreferencesManager.shared

    let snippet: TerminalSnippet?

    @State private var title: String
    @State private var content: String
    @State private var sendMode: TerminalSnippetSendMode
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    private var isEditing: Bool {
        snippet != nil
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (isEditing || preferences.canCreateSnippet)
    }

    init(snippet: TerminalSnippet? = nil) {
        self.snippet = snippet
        _title = State(initialValue: snippet?.title ?? "")
        _content = State(initialValue: snippet?.content ?? "")
        _sendMode = State(initialValue: snippet?.sendMode ?? .insert)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $content)
                            .frame(minHeight: 120)
                    }
                } header: {
                    Text("Snippet")
                } footer: {
                    Text(
                        "\(title.count)/\(TerminalAccessoryProfile.maxSnippetTitleLength) title chars • \(content.count)/\(TerminalAccessoryProfile.maxSnippetContentLength) content chars"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Mode", selection: $sendMode) {
                        ForEach(TerminalSnippetSendMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Send Behavior")
                } footer: {
                    Text("Snippets send exactly as written. Ctrl/Alt modifiers are ignored for snippet taps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Avoid storing secrets in snippets.")
                        .foregroundStyle(.orange)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Snippet")
                                Spacer()
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Snippet" : "New Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSnippet()
                    }
                    .disabled(!canSave)
                }
            }
            .alert("Delete Snippet?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    guard let snippet else { return }
                    preferences.deleteSnippet(id: snippet.id)
                    dismiss()
                }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }

    private func saveSnippet() {
        do {
            if let snippet {
                try preferences.updateSnippet(
                    id: snippet.id,
                    title: title,
                    content: content,
                    sendMode: sendMode
                )
            } else {
                _ = try preferences.createSnippet(
                    title: title,
                    content: content,
                    sendMode: sendMode
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
