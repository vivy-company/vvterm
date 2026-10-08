import SwiftUI

struct TerminalCustomActionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: TerminalAccessoryPreferencesManager
    @EnvironmentObject private var storeManager: StoreManager

    let action: TerminalAccessoryCustomAction?

    @State private var title: String
    @State private var kind: TerminalAccessoryCustomActionKind
    @State private var commandContent: String
    @State private var commandSendMode: TerminalSnippetSendMode
    @State private var shortcutKey: TerminalAccessoryShortcutKey
    @State private var shortcutModifiers: TerminalAccessoryShortcutModifiers
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    private var isEditing: Bool {
        action != nil
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (kind == .shortcut || !commandContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (isEditing || preferences.canCreateCustomAction)
    }

    private var shortcutPreview: String {
        shortcutModifiers.displayTitle(for: shortcutKey.title)
    }

    init(action: TerminalAccessoryCustomAction? = nil) {
        self.action = action
        _title = State(initialValue: action?.title ?? "")
        _kind = State(initialValue: action?.kind ?? .command)
        _commandContent = State(initialValue: action?.commandContent ?? "")
        _commandSendMode = State(initialValue: action?.commandSendMode ?? .insert)
        _shortcutKey = State(initialValue: action?.shortcutKey ?? .a)
        _shortcutModifiers = State(initialValue: action?.shortcutModifiers ?? .none)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)

                    Picker("Type", selection: $kind) {
                        ForEach(TerminalAccessoryCustomActionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Custom Action")
                } footer: {
                    Text(
                        String(
                            format: String(localized: "Title length: %lld/%lld"),
                            Int64(title.count),
                            Int64(TerminalAccessoryProfile.maxCustomActionTitleLength)
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if kind == .command {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Content")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TerminalActionTextEditor(text: $commandContent)
                        }
                    } footer: {
                        Text(
                            String(
                                format: String(localized: "Command length: %lld/%lld"),
                                Int64(commandContent.count),
                                Int64(TerminalAccessoryProfile.maxCommandContentLength)
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Picker("Send Behavior", selection: $commandSendMode) {
                            ForEach(TerminalSnippetSendMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Commands send exactly as written.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TerminalShortcutFields(key: $shortcutKey, modifiers: $shortcutModifiers)
                    } header: {
                        Text("Shortcut")
                    } footer: {
                        Text(shortcutPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Avoid storing secrets in commands or action titles.")
                        .foregroundStyle(.orange)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Custom Action")
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
            .navigationTitle(
                isEditing
                    ? String(localized: "Edit Custom Action")
                    : String(localized: "New Custom Action")
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetDismissButton(title: "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmationButton(title: "Save", action: saveAction)
                    .disabled(!canSave)
                }
            }
            .alert("Delete Custom Action?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    guard let action else { return }
                    preferences.deleteCustomAction(id: action.id)
                    dismiss()
                }
            } message: {
                Text("This cannot be undone.")
            }
        }
        .adaptiveSoftScrollEdges()
    }

    private func saveAction() {
        do {
            if let action {
                try preferences.updateCustomAction(
                    id: action.id,
                    title: title,
                    kind: kind,
                    commandContent: commandContent,
                    commandSendMode: commandSendMode,
                    shortcutKey: shortcutKey,
                    shortcutModifiers: shortcutModifiers
                )
            } else {
                _ = try preferences.createCustomAction(
                    title: title,
                    kind: kind,
                    commandContent: commandContent,
                    commandSendMode: commandSendMode,
                    shortcutKey: shortcutKey,
                    shortcutModifiers: shortcutModifiers,
                    hasProAccess: storeManager.allowsProFeatures
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
